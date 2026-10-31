// The Action Cable broadcasts of examples/cable.axum.rb, driven over real WebSockets with node alone: two clients
// (alice and bob) subscribe, and a broadcast from a route, from a channel's `perform` and from its lifecycle
// callbacks must reach exactly the subscribers on that broadcasting name, as the exact frame Rails writes:
//
//   {"identifier":"<the identifier string as the client sent it>","message":<payload>}
//
// where the payload is a JSON object (keys in the order written) for `broadcast`/`broadcast_to`, and the
// `<turbo-stream>` tag as a JSON string for `broadcast_turbo`, with `<`, `>` and `&` written as <, > and
// & (ActiveSupport's JSON escaping). The expected text below is built here, from those rules, not copied
// from the service. test/e2e_cable.sh starts the service; no package: the WebSocket client is the small RFC 6455
// subset the check needs (the same one campfire_axum_dsl/test/cable_check.mjs uses).
// usage: node test/cable_broadcast_check.mjs [BASE_URL]      (default http://127.0.0.1:8105)
import crypto from "node:crypto"
import http from "node:http"

const base = process.argv[2] ?? "http://127.0.0.1:8105"
const origin = new URL(base)
const host = origin.hostname
const port = Number(origin.port || 80)
const PROTOCOL = "actioncable-v1-json"

let failed = 0
const ok = (text) => console.log(`ok: ${text}`)
const bad = (error) => {
  failed++
  console.error(`FAIL: ${error instanceof Error ? error.message : String(error)}`)
}

function send(method, path, headers = {}) {
  return new Promise((resolve, reject) => {
    const request = http.request({ host, port, method, path, headers, agent: false }, (response) => {
      const chunks = []
      response.on("data", (chunk) => chunks.push(chunk))
      response.on("end", () => resolve({ status: response.statusCode, headers: response.headers, body: Buffer.concat(chunks).toString("utf8") }))
    })
    request.on("error", reject)
    request.end()
  })
}

async function login(name) {
  const response = await send("POST", `/login/${name}`)
  const cookie = (response.headers["set-cookie"] ?? []).map((value) => value.split(";")[0]).find((value) => value.startsWith("who="))
  if (!cookie) throw new Error(`POST /login/${name} answered HTTP ${response.status} without a who cookie`)
  return cookie
}

class WebSocket {
  constructor(socket) {
    this.socket = socket
    this.buffer = Buffer.alloc(0)
    this.queue = []
    this.waiters = []
    this.closed = false
    this.failure = null
    socket.on("data", (chunk) => {
      this.buffer = Buffer.concat([this.buffer, chunk])
      this.drain()
    })
    socket.on("close", () => this.stop(new Error("the server closed the socket")))
    socket.on("error", (error) => this.stop(error))
  }

  stop(error) {
    if (this.closed) return
    this.closed = true
    this.failure = error
    for (const waiter of this.waiters.splice(0)) {
      clearTimeout(waiter.timer)
      waiter.reject(error)
    }
  }

  drain() {
    try {
      for (;;) {
        const frame = this.frame()
        if (!frame) return
        if (frame.opcode === 0x1) this.deliver(frame.payload.toString("utf8"))
        else if (frame.opcode === 0x8) {
          this.stop(new Error("the server sent a close frame"))
          return
        } else if (frame.opcode === 0x9) this.write(0xa, frame.payload)
      }
    } catch (error) {
      this.stop(error)
    }
  }

  frame() {
    const bytes = this.buffer
    if (bytes.length < 2) return null
    const opcode = bytes[0] & 0x0f
    const masked = (bytes[1] & 0x80) !== 0
    let length = bytes[1] & 0x7f
    let at = 2
    if (length === 126) {
      if (bytes.length < at + 2) return null
      length = bytes.readUInt16BE(at)
      at += 2
    } else if (length === 127) {
      if (bytes.length < at + 8) return null
      length = Number(bytes.readBigUInt64BE(at))
      at += 8
    }
    let mask = null
    if (masked) {
      if (bytes.length < at + 4) return null
      mask = bytes.subarray(at, at + 4)
      at += 4
    }
    if (bytes.length < at + length) return null
    const payload = Buffer.from(bytes.subarray(at, at + length))
    if (mask) for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i % 4]
    this.buffer = bytes.subarray(at + length)
    return { opcode, payload }
  }

  write(opcode, payload) {
    if (this.closed) throw new Error("the socket is already closed")
    const length = payload.length
    let header
    if (length < 126) {
      header = Buffer.from([0x80 | opcode, 0x80 | length])
    } else if (length < 65536) {
      header = Buffer.alloc(4)
      header[0] = 0x80 | opcode
      header[1] = 0x80 | 126
      header.writeUInt16BE(length, 2)
    } else {
      header = Buffer.alloc(10)
      header[0] = 0x80 | opcode
      header[1] = 0x80 | 127
      header.writeBigUInt64BE(BigInt(length), 2)
    }
    const mask = crypto.randomBytes(4)
    const masked = Buffer.from(payload)
    for (let i = 0; i < masked.length; i++) masked[i] ^= mask[i % 4]
    this.socket.write(Buffer.concat([header, mask, masked]))
  }

  sendText(text) {
    this.write(0x1, Buffer.from(text))
  }

  deliver(text) {
    if (text.startsWith('{"type":"ping"')) return // the 3 second ping is not a message under test
    const waiter = this.waiters.shift()
    if (!waiter) {
      this.queue.push(text)
      return
    }
    clearTimeout(waiter.timer)
    waiter.resolve(text)
  }

  next(timeout = 3000) {
    if (this.queue.length) return Promise.resolve(this.queue.shift())
    if (this.closed) return Promise.reject(this.failure ?? new Error("the socket is closed"))
    return new Promise((resolve, reject) => {
      const waiter = { resolve, reject, timer: null }
      waiter.timer = setTimeout(() => {
        const at = this.waiters.indexOf(waiter)
        if (at >= 0) this.waiters.splice(at, 1)
        reject(new Error(`no WebSocket frame within ${timeout} ms`))
      }, timeout)
      this.waiters.push(waiter)
    })
  }

  close() {
    if (this.closed) return
    try {
      this.write(0x8, Buffer.alloc(0))
    } catch {}
    this.stop(new Error("the check closed the socket"))
    this.socket.destroy()
  }
}

function open(cookie) {
  const headers = {
    Connection: "Upgrade",
    Upgrade: "websocket",
    "Sec-WebSocket-Key": crypto.randomBytes(16).toString("base64"),
    "Sec-WebSocket-Version": "13",
    "Sec-WebSocket-Protocol": PROTOCOL,
  }
  if (cookie) headers.Cookie = cookie
  return new Promise((resolve, reject) => {
    const request = http.request({ host, port, path: "/cable", method: "GET", headers, agent: false })
    request.on("upgrade", (response, socket, head) => {
      const ws = new WebSocket(socket)
      if (head?.length) {
        ws.buffer = Buffer.concat([ws.buffer, head])
        ws.drain()
      }
      resolve(ws)
    })
    request.on("response", (response) => {
      response.resume()
      reject(new Error(`GET /cable did not upgrade: HTTP ${response.statusCode}`))
    })
    request.on("error", reject)
    request.end()
  })
}

// What a Rails frame looks like: ActiveSupport's JSON turns <, > and & into <, > and &.
const escapeHtml = (json) => json.replaceAll("<", "\\u003c").replaceAll(">", "\\u003e").replaceAll("&", "\\u0026")
const frame = (identifier, messageJson) => escapeHtml(`{"identifier":${JSON.stringify(identifier)},"message":${messageJson}}`)

// The tag turbo-rails writes: extra attributes, then action, then target; remove has no template.
const turbo = (action, target, html, extra = "") =>
  `<turbo-stream${extra} action="${action}" target="${target}">${html === undefined ? "" : `<template>${html}</template>`}</turbo-stream>`

const identifier = (fields) => JSON.stringify(fields)

async function expectFrame(label, ws, expected) {
  try {
    const got = await ws.next()
    if (got === expected) ok(label)
    else bad(`${label}\n      wanted ${expected}\n      got    ${got}`)
  } catch (error) {
    bad(`${label}: ${error.message}`)
  }
}

// The server closed the socket: its close frame (or the TCP close) arrived, not a timeout.
async function expectClosed(label, ws) {
  try {
    const got = await ws.next()
    bad(`${label}: got the frame ${got} instead of a close`)
  } catch (error) {
    if (/server (sent a close frame|closed the socket)/.test(error.message)) ok(label)
    else bad(`${label}: ${error.message}`)
  }
}

// A client has nothing queued: no stray frame arrived (the caller has already waited for a later one).
function expectNothing(label, ws) {
  if (ws.queue.length === 0) ok(label)
  else bad(`${label}: ${ws.queue.length} unexpected frame(s), the first ${ws.queue[0]}`)
}

async function subscribe(ws, fields) {
  const text = identifier(fields)
  ws.sendText(JSON.stringify({ command: "subscribe", identifier: text }))
  const expected = `{"identifier":${JSON.stringify(text)},"type":"confirm_subscription"}`
  await expectFrame(`${fields.channel} is confirmed`, ws, expected)
  return text
}

async function welcome(ws) {
  const first = await ws.next()
  if (first !== '{"type":"welcome"}') throw new Error(`the first frame is ${first}, wanted welcome`)
}

const sockets = []
try {
  const alice = await open(await login("alice"))
  const bob = await open(await login("bob"))
  sockets.push(alice, bob)
  await welcome(alice)
  await welcome(bob)
  ok("alice and bob are connected")

  // broadcast from a route to a per-user stream (stream_from)
  const notices = identifier({ channel: "NoticesChannel" })
  await subscribe(alice, { channel: "NoticesChannel" })
  await subscribe(bob, { channel: "NoticesChannel" })
  await send("POST", "/notify/bob")
  await expectFrame("a route's broadcast reaches the subscriber of that name, keys in the order written", bob,
    frame(notices, '{"message":"hello","to":"bob"}'))
  await send("POST", "/notify/alice")
  await expectFrame("and only that name: alice's next frame is her own notice", alice, frame(notices, '{"message":"hello","to":"alice"}'))
  expectNothing("alice never saw bob's notice", alice)

  // after_subscribe: the join is broadcast to the log
  const log = await subscribe(bob, { channel: "LogChannel" })
  const roomOf = (id) => ({ channel: "ChatChannel", room_id: id })
  const chat = await subscribe(alice, roomOf(7))
  await expectFrame("after_subscribe broadcasts after the confirmation", bob, frame(log, '{"event":"joined","user":"alice","room_id":7}'))
  await subscribe(bob, roomOf(7))
  await expectFrame("bob's join reaches the log too", bob, frame(log, '{"event":"joined","user":"bob","room_id":7}'))

  // perform: a client's message calls the channel's action, and broadcast_to reaches everyone on the stream_for name
  const speak = JSON.stringify({ action: "speak" })
  alice.sendText(JSON.stringify({ command: "message", identifier: chat, data: speak }))
  const spoken = frame(chat, '{"action":"speak","user":{"name":"alice","room":7}}')
  await expectFrame("perform :speak reaches the speaker", alice, spoken)
  await expectFrame("perform :speak reaches the other subscriber", bob, spoken)
  alice.sendText(JSON.stringify({ command: "message", identifier: chat, data: JSON.stringify({ action: "nope" }) }))
  bob.sendText(JSON.stringify({ command: "message", identifier: chat, data: JSON.stringify({ action: "speak" }) }))
  const bobSpoken = frame(chat, '{"action":"speak","user":{"name":"bob","room":7}}')
  await expectFrame("an action the channel does not declare is dropped: alice's next frame is bob's speak", alice, bobSpoken)
  await expectFrame("bob hears himself", bob, bobSpoken)

  // a Turbo signed stream: broadcast_turbo from routes
  const signed = (await send("GET", "/stream_name")).body
  const board = await subscribe(alice, { channel: "BoardChannel", signed_stream_name: signed })
  await subscribe(bob, { channel: "BoardChannel", signed_stream_name: signed })
  await send("POST", "/board/a%26b")
  const append = frame(board, JSON.stringify(turbo("append", "notes", '<p class="note">a&amp;b</p>', ' maintain_scroll="true"')))
  await expectFrame("broadcast_turbo append: the tag as a JSON string, html escaped as Rails escapes it", alice, append)
  await expectFrame("broadcast_turbo append reaches every subscriber", bob, append)
  await send("DELETE", "/board/a%26b")
  const remove = frame(board, JSON.stringify(turbo("remove", "note_a&amp;b")))
  await expectFrame("broadcast_turbo remove has no template", alice, remove)
  await expectFrame("broadcast_turbo remove reaches every subscriber", bob, remove)

  // unsubscribe: on_unsubscribe runs, and the subscription is gone from its streams
  bob.sendText(JSON.stringify({ command: "unsubscribe", identifier: chat }))
  await expectFrame("on_unsubscribe broadcasts the leave", bob, frame(log, '{"event":"left","user":"bob","room_id":7}'))
  alice.sendText(JSON.stringify({ command: "message", identifier: chat, data: speak }))
  await expectFrame("alice still hears her room", alice, spoken)
  await send("POST", "/notify/bob")
  await expectFrame("bob has left the room: the next thing he hears is the notice", bob, frame(notices, '{"message":"hello","to":"bob"}'))

  // a closed socket drops every subscription it held
  alice.close()
  await expectFrame("a closed socket runs on_unsubscribe for what it held", bob, frame(log, '{"event":"left","user":"alice","room_id":7}'))
  await send("POST", "/board/gone")
  const stillThere = frame(board, JSON.stringify(turbo("append", "notes", '<p class="note">gone</p>', ' maintain_scroll="true"')))
  await expectFrame("bob is still on the board after alice left", bob, stillThere)

  // close_remote_connections: both of carol's sockets get the remote disconnect and are closed, running on_unsubscribe;
  // bob's socket stays open
  const carol = await login("carol")
  const carol1 = await open(carol)
  const carol2 = await open(carol)
  sockets.push(carol1, carol2)
  await welcome(carol1)
  await welcome(carol2)
  await subscribe(carol1, roomOf(9))
  await expectFrame("carol's join reaches the log", bob, frame(log, '{"event":"joined","user":"carol","room_id":9}'))
  await subscribe(carol2, { channel: "NoticesChannel" })
  const kicked = await send("POST", "/kick/carol")
  if (kicked.status === 200) ok("POST /kick/carol answers without waiting for the sockets")
  else bad(`POST /kick/carol answered HTTP ${kicked.status}`)
  const remote = '{"type":"disconnect","reason":"remote","reconnect":true}'
  await expectFrame("carol's first socket is sent the remote disconnect (reconnect true)", carol1, remote)
  await expectFrame("carol's second socket is sent it too", carol2, remote)
  await expectClosed("carol's first socket is closed after it", carol1)
  await expectClosed("carol's second socket is closed after it", carol2)
  await expectFrame("closing carol's socket ran on_unsubscribe", bob, frame(log, '{"event":"left","user":"carol","room_id":9}'))
  await send("POST", "/notify/bob")
  await expectFrame("bob's socket stayed open: his next frame is his own notice", bob, frame(notices, '{"message":"hello","to":"bob"}'))

  // a socket opened afterwards is not affected, and `reconnect: false` says so in the frame
  const carol3 = await open(carol)
  sockets.push(carol3)
  await welcome(carol3)
  await send("POST", "/kick/carol/final")
  await expectFrame("reconnect: false is written in the frame", carol3, '{"type":"disconnect","reason":"remote","reconnect":false}')
  await expectClosed("and the socket is closed", carol3)
} catch (error) {
  bad(error)
} finally {
  for (const ws of sockets) ws.close()
}

let anonymous
try {
  anonymous = await open()
  const first = await anonymous.next()
  if (first === '{"type":"disconnect","reason":"unauthorized","reconnect":false}') ok("a connection without a cookie is told disconnect unauthorized")
  else bad(`a connection without a cookie got ${first}`)
} catch (error) {
  bad(error)
} finally {
  anonymous?.close()
}

if (failed) {
  console.error(`FAIL: ${failed} Action Cable broadcast check(s) failed`)
  process.exit(1)
}
console.log("OK: every Action Cable broadcast check passed")
