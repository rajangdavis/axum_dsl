# Capabilities

_Design note: nothing in this file is implemented yet. It describes the layer above `before`, `current`,
`view_local`, `page_locals` and `layout_locals`. See also: [Controllers](controllers.md), [Views](views.md),
[The DSL](dsl.md)._

## The problem

A controller in `campfire_axum_dsl` currently does three jobs at once:

1. **Policy** — who may reach it: `before :authenticate`, `before :ensure_can_administer`, the banned-IP
   filter, the session rate limit.
2. **Context** — what the chrome needs: `layout_locals` blocks repeated in eleven controllers, `body_flags`
   calls in twenty actions, `take_flash`, and fifteen `pwa_*` page locals in one controller.
3. **Orchestration** — load, mutate, respond: `room_for_user`, the message transaction, the `locals:` hashes.

Only (3) is the controller's. Policy is a property of the route; context is a property of the view. Both should be
declared once, by the thing that owns them, not copied into every controller that happens to render a page.

The end-state is: **views are the contract, capabilities are the providers, controllers are policy and
orchestration.** A view already declares the names it reads, and the compiler already refuses a missing or an extra
local. A capability should own a domain record, the filters that establish it, and the locals its views read; a
controller or a route should only name the capabilities it wants.

Then the normal render is `render :room_show, from: page, messages: messages`, and a controller has no
`layout_locals` block at all.

## The layer stack

Six layers, outermost to innermost. Each has a different mechanism, and the middle four are not generic
middleware: each capability owns the domain record and the policy for it.

| Layer | Mechanism today | Campfire examples | Capability |
|---|---|---|---|
| Request normalization | `use_layer` (outer middleware) | `method_override`, `format_extension`, `fetch_metadata`, `csrf`, `front` (Date) | `:rails_http`, `:csrf`, `:front` |
| **Policy** | ordered `before` filters, `skip:` | `authenticate`, `reject_banned_ip`, `ensure_can_administer`, `rate_limited?` | `:identity`, `:ban`, `:admin`, `:rate_limit` |
| **Context** | `current` records + local blocks | `current :user`, `body_flags` ×20, `layout_locals` ×11, `pwa_*` | `:identity`, `:chrome`, `:flash`, `:pwa` |
| **Binding** | `before … provides:` | `set_room`, `room_for_user` | `:room`, `:membership`, `:resource` |
| **Response** | helpers the capability extends | `redirect(…, notice:)`, `etag`, `cache:` | `:flash`, `:cache` |
| Representation | partials/streams with typed args | `render_string(:message_broadcast, locals: {…})` | `:broadcast`, `:json` |
| Domain | models, queries, transactions | `room_page`, `body_flags`, `create_message` | — (stays) |

## Two primitives

Everything else falls out of two additions to what already exists.

### 1. A capability is a memoized per-request record

`current :user` is already computed once per request and read with `current(:user)`. Generalize that: a
capability declares a record, the filters that establish it, and the locals that read its fields.

```ruby
capability :chrome do
  current :chrome, returns: :Chrome do
    body_flags(user_id: current_user.id) || raise("the user was not read back")
  end

  layout_locals from: :chrome do
    logo_version = logo_version
    account_css  = account_css
    user_title   = title
    user_version = version
  end

  page_locals from: :chrome do
    body_class = body_class
    has_logo   = logo == 1
  end
end
```

`body_flags` stops being a per-action query and an eleven-controller copy of `layout_locals`; it is one
`current` record and a field mapping. Only a render whose view reads a name computes it, as with `view_local`
today.

### 2. Record-backed locals: `from:`

This is the primitive that removes the giant `locals:` hashes:

```ruby
render :room_show, from: page, messages: messages
broadcast :message_broadcast, from: message, base_url: broadcast_base
```

The view's marker names and the record's fields meet by name, at compile time. Proposed rules, which keep the
exactness `locals:` already enforces:

- an explicit `locals:` key wins, and suppresses the record field of that name;
- a record field whose name a marker reads binds that name;
- a marker with no field and no local is refused, naming the view, the line and the name;
- a field no marker reads is refused, as an extra `locals:` key is today;
- a field whose type a marker cannot write is refused at the record's declaration.

_Implemented 2026-11-12 for `render` and `render_string` (see [Views](views.md), "Locals from a record"), with one difference: a record field no marker reads is ignored, not refused. A name that is both a route local (or a page/layout/view_local entry) and a record field is refused, as here, and an explicit `locals:` entry resolves it. `broadcast from:` and the capability records are not implemented._

`{% args %}` is the same contract for a partial, so a `broadcast from:` checks the partial's arguments too.

## Capability shape

Proposed syntax, deliberately close to the declarations that exist:

```ruby
capability :identity do
  order 10
  current :user, returns: :User? do
    current_user_by_session(cookie: cookie(:session_token))
  end
  before :authenticate, skip: :public, redirect: "/session/new"
  layout_locals do
    signed_in = !current(:user).nil?
    user_id   = signed_in ? current(:user).id : ""
    user_name = signed_in ? current(:user).name : ""
  end
end

capability :admin, after: :identity do
  before :ensure_can_administer
end

capability :flash, after: :identity do
  # owns the flash cookie, take_flash, and the three layout names
  layout_locals do
    flash      = take_flash
    flash_on   = flash.on
    flash_alert = flash.alert
    flash_text = flash.text
  end
end

capability :pwa do
  page_locals do
    pwa_browser = pwa_browser(user_agent)
    pwa_os      = pwa_os(user_agent)
    # … the other pwa_* flags …
  end
end
```

A controller then states only policy:

```ruby
controller "Accounts::Bots" do
  capability :admin

  def index
    render :account_bots, from: account_bots_page
  end
end
```

and, in the route table, a scope can carry the same policy:

```ruby
scope path: "account", capabilities: [:admin] do
  resources :bots
end

post "/session", capabilities: [:public], rate_limit: { to: 10, within: 180 }
```

## The app folder

Rails' `app/` is the right map for the port: the same buckets the reference app has, so a Rails developer can
find a file without learning a new tree. Today's root-level `controllers/`, `models/` and `views/` are that idea
without the bucket.

```
campfire_axum_dsl/
  app/
    capabilities/      # a concern + its initializer + its laws: identity, flash, chrome, pwa, admin, room
    commands/          # units of work: a transaction and the effects that follow its commit
    controllers/       # one Rails controller per file, action defs only
    models/            # records, queries, model defs
    views/             # the contract
  config/
    routes.axum.rb     # the route table
  db/migrate/
  test/
    laws/              # capability laws, if they are not kept beside their capability
    parity/
  campfire.axum.rb     # server entry: settings, use_dsl order, cable
```

| Rails | campfire_axum_dsl |
|---|---|
| `app/controllers` | `app/controllers` |
| `app/models` | `app/models` |
| `app/views` | `app/views` |
| `app/controllers/concerns` + `config/initializers` | `app/capabilities` |
| model method / form object / service object | `app/commands` |
| `app/jobs` | `later do … end` inside an `after_commit` effect |
| `config/routes.rb` | `config/routes.axum.rb` |
| `db/migrate` | `db/migrate` |
| `test` | `test/laws`, `test/parity` |
| `public/`, `app/assets`, `app/javascript` | `static/`, `pwa/` |

One implementation note: `controller do` and `model do` infer their name from the file's path **under
`controllers/` or `models/`** (`reader.rb#inferred_name`), so moving to `app/controllers` needs the reader to
accept the optional `app/` segment; `set :views, "app/views"` points the renderer at the new folder, and
`use_dsl "config/routes.axum.rb"` replaces the root path. That is a small, mechanical change; `dsl-golden` proves
the move emits byte-identical code.

What does not copy: no `app/assets`/`app/javascript` (the static mount and `pwa/` already are those), no
`app/mailers`, and `app/helpers` only if helpers grow into files of their own.

## Transactions and commands

`transaction do … end` is already a strict primitive: SQL statements only, no nesting, no `return`/`raise`, a
database error rolls the whole block back, and the value comes back after commit ([Database](database.md)).
That is the right shape. What is missing is a home for a transaction and a way to hang effects off its commit.

Today `rooms.axum.rb#post_message` is a 150-line action that mixes BEGIN/COMMIT, broadcasts, Web Push, bot
webhooks and the HTTP response in one body. Rails puts the unit of work in a model method (or a form/service
object) and hangs `after_commit` callbacks off it:

```ruby
# app/commands/publish_message.axum.rb
command :publish_message, args: { room_id: :i64, creator_id: :i64, body: :string, attachment: :upload? },
                          returns: :Message do
  key = …                                   # compute before BEGIN; a transaction may not store a file inside itself
  message_id = transaction do
    id = create_message(room_id: room_id, creator_id: creator_id, …)
    create_message_body(message_id: id, body: body)
    # … the blob, FTS row, room touch, receive
    after_commit do
      broadcast_message(id)                 # render_string + broadcast_turbo
      later { deliver_pushes(id) }          # after the answer, as today
    end
    id
  end
  message_row(id: message_id) || raise("the new message was not read back")
end
```

```ruby
def post_message
  message = publish_message(room_id: room.id, creator_id: current_user.id,
                         body: params[:body], attachment: params[:attachment])
  render :message_stream, from: message, kind: room.kind
end
```

`after_commit` is the one non-SQL form the block would allow: it registers a closure that runs **only when the
transaction commits**, outside the SQL closure, in declaration order. It can capture the ids the block created
(move semantics, as `later` already does) and schedule post-response work with `later`. It cannot write SQL after
BEGIN — that is the rule that keeps the transaction retryable. `after_rollback` is not needed yet.

Why this belongs in the capability/cost discussion:

- **Correctness**: an effect cannot run on a rolled-back write, and a committed write cannot lose its
  broadcast/push because an effect was written after the commit by hand. The law is one line: force the
  transaction to fail and assert no broadcast and no push were queued; commit and assert exactly one.
- **Speed**: the emitted Rust keeps the same `BEGIN IMMEDIATE`/`COMMIT`, the same statements and the same single
  transaction per command. The effect closure is the existing `later` machinery; no new query, no extra
  allocation on the response path.
- **Size**: `post_message` becomes the verb and the render; the 100 lines of side effects move to the command,
  where they are named and testable.

The same extraction applies to `accounts/bots#create|update`, `profiles#update`, `messages#update|destroy`,
`boosts#create`, `first_run#create`, and `users#create`. Each is one command with a transaction and a small
action, and each gets a law for its commit/rollback effects.

## Ordering

Order is the feature, not an implementation detail. A capability declares `order:` or `after:`, and a route's
filters run in that order after the top-level ones. The Campfire chain must be:

```
identity → ban → rate limit → authorization (admin/member) → resource binding
```

A route that declares a rate limit cannot run it before `:ban` unless the capability says `after: :ban`; the
compiler refuses a cycle, a capability that names a filter it does not declare, and two capabilities that claim
the same order without a tie-break.

GAPS #19 in `campfire_axum_dsl` is the argument for making this declarative: the rate limiter answered before
the banned-IP filter, and the response differed only by which layer saw the request first. A comment in
`campfire.axum.rb` and a state-accumulation test are not the right place for that order.

## Laws

A capability is a claim: these filters run in this order, this record exists, these names are bound. A claim
without a test is a comment. The compiler already has the test form: a `law` becomes a proptest in the generated
crate, and a route law drives the real router in-process through `respond` ([Laws](laws.md)).

Campfire already has two capability law files without the name:

- `test/laws/flash.axum.rb` — `:identity` and `:flash`: the `tok` / `tok.<key>` cookie state machine, a notice
  shown once, `/` passing an unread alert on, and no session answered by a redirect to `/session/new`.
- `test/laws/accounts.axum.rb` — `:admin`: a member gets 403 and an administrator 200 on every account page,
  every write refuses a member before it changes anything, and an unknown id is 404.

Those files already say what "the capability works" means. The change is to name them after capabilities rather
than controllers, and to give every other capability the same file.

Three kinds of law, three homes:

- **Route laws** (`respond`) are the main kind. One file per capability: `identity`, `flash`, `ban`,
  `rate_limit`, `admin`, `chrome`, `pwa`, `rooms`. The identity law is the pattern the rest follow: no session
  → 302 to `/session/new`; a `skip:`/public route answers without one; a signed-in member gets 200.
- **Property laws** (`forall:`) quantify the data side: any id that is not an active bot is 404, a bucket admits
  exactly `to` requests, a random room id is either 200 for its member or the same miss for everyone else.
- **Refusal laws** are compile-time and belong in `test/refusals/`: a `from:` record missing a marker's field,
  an extra field, a name that is both a route local and a capability field, a capability naming no def, a cycle
  in `after:`. A capability's contract is only as precise as its refusals.

Ordering is a law too. The one that would have caught GAPS #19: after the sign-in limit is spent, a banned
`POST /session` must answer the ban filter's `text/html` 429, not the limiter's `text/plain` 429. Written once,
an `after:` change that gets the order wrong fails a test rather than a parity run.

Proposed enforcement:

- a law may name the capability it covers: `law :a_notice_is_shown_once, capability: :flash do ... end`;
- `axum_dsl test` reports capability coverage beside route coverage ([Coverage](coverage.md)); a declared
  capability with no law is a failure, or at least a named warning;
- the laws stay one `test/laws/run.sh`, grouped by capability.

## The generated Rust: cost and correctness

A capability must be **compile-time sugar**, not a runtime framework. The emitted crate has to stay the hand-written
crate's equal in work per request; an abstraction that needs a registry, a dynamic lookup or an extra query is the
wrong abstraction.

### Expansion, not interpretation

- A capability declaration is expanded by the compiler into the same declarations the hand-written version has:
  `before` defs, `let __vl_…` locals, record field reads. There is no capability registry, no vector of boxed
  filters and no capability name in the binary.
- Ordering (`after:`, `order:`) is resolved at compile time into the nested/straight-line filter sequence. A wrong
  order is a compile error, not a runtime check.
- `render :room_show, from: page, messages: messages` emits the same code as the explicit `locals:` hash. A
  capability's `layout_locals`/`page_locals` emit the same `let` as the hand-written block. `dsl-golden` is the
  proof: the capability diff should be the expansion, not a different shape.

### Cost rules

- **One computation per request.** A `current` record is computed once, and later reads are field accesses on a
  concrete type. It must not become a string-keyed map lookup or a fresh query per read. Prefer `provides:` where
  the value naturally flows through a filter; a typed request extension is the fallback for values several
  unrelated filters read.
- **Lazy, as `view_local` is.** A capability's query runs only when a render reads one of its names; a route that
  never reads `chrome` never runs `body_flags`. `from:` must not materialize or compute a field no marker reads.
- **No added queries.** `:chrome` folds `body_flags` into an existing page read; `:pwa` is pure functions of
  `user_agent`; `:flash` reads the cookie once. A capability that adds a query to a route it did not serve before
  is refused at review.
- **No added allocation.** A capability must not introduce a `String`, `Vec` or clone the hand-written code did
  not. The flash record and the pwa flags are the same values they are today.
- **Cache parity.** A capability must not change the response-cache key or add a header the hand-written code did
  not. Values derived from the request already enter the key through its headers.

### The gate for every wave

Each migration wave must pass all of:

1. `dsl-check` (Ruby compile);
2. the capability's laws (`test/laws/<capability>.axum.rb`) plus the refusal tests it owns;
3. `dsl-golden`, to show the emitted-code diff is only the expansion;
4. the parity sample for the routes the wave touches;
5. `dsl-bench` with a fresh `LABEL` against the pre-capability `BASELINE`, on
   `room_show,messages_page,sidebar,search,post_message` — no regression in throughput or allocations.

A wave that cannot show its emitted code is unchanged (or only expanded) does not ship, even if the tests pass.
Correctness is the laws and the exact-match refusals; speed is the expansion rule and the benchmark. Neither is
allowed to become "we'll measure it later".

## Worked example: Campfire, in waves

Each wave is independently verifiable: emitted-code diff, laws, parity sample, and a `dsl-bench` comparison
against the pre-capability baseline. Waves 1 and 2 do not change the emitted code.

1. **Chrome, with no new syntax.** Add `current :chrome` around `body_flags`, then let it provide
   `logo_version`, `account_css`, `vapid_key`, `user_title`, `user_version`, `body_class` and `has_logo` as
   layout/page locals. Delete the twenty `body_flags(...)` calls in actions and the eleven duplicated
   `layout_locals` blocks. Add `test/laws/chrome.axum.rb` (`body_class`, `logo_version` and `user_title` on a
   room page, the account page and the sidebar), then verify with `dsl-check`, `rooms/show/**` and `account/**`
   parity.
2. **Name the capabilities as fragments.** Declare `:identity`, `:admin`, `:flash`, `:ban` as fragments that
   expand to today's `before` filters and local blocks. Split `test/laws/flash.axum.rb` into
   `identity.axum.rb` (no session → sign-in) and `flash.axum.rb` (the token state machine, a notice shown once);
   rename `accounts.axum.rb` to `admin.axum.rb`; add `ban.axum.rb` (a banned non-GET is `text/html` 429, a banned
   GET passes) and `rate_limit.axum.rb` (the tenth request allowed, the eleventh 429, a banned request not
   counted). No compiler change: the app reads declaratively while the emitted code stays the same.
3. **`render from:` for Rooms.** Make `RoomPage` carry the view's fields (`body_class`, `direct`, `noun`, `kind`,
   `plural`, `has_logo`, `updated_ms`, `user_title`, `user_version`, `can_administer`, `title`, `room_id`,
   `room_name`), then `render :room_show, from: page, messages: messages`. Do the same for the three
   `render_string(:message_broadcast, …)` call sites. Add the refusal laws (missing field, extra field, ambiguous
   local, wrong type); no runtime law changes, because the emitted code is unchanged.
4. **Ordered policy.** Declare `:rate_limit, after: :ban` and `:admin, after: :identity`; remove the ordering
   comment from `campfire.axum.rb` and the `rate_limited?` call from the session action. Add the GAPS #19 law:
   after the limit is spent, a banned `POST /session` still answers the ban filter's `text/html` 429. It passes
   today; the law is there so a later `after:` edit cannot regress it.
5. **`:pwa` and `:room`.** `:pwa` hoists the fifteen flags out of `rooms.axum.rb` and `profiles.axum.rb`; add
   `pwa.axum.rb` (the UA table and the incompatible-browser gate). `:room` replaces `before :set_room` /
   `room_for_user` with a finder and a miss policy, so the permalink's plain redirect and the room page's
   `alert: :room_not_found` are two options of one capability; add `rooms.axum.rb` (member and non-member, both
   miss policies, the permalink's flash behavior).
6. **The app folder.** `git mv controllers app/controllers`, `models app/models`, `views app/views`; move the
   concerns to `app/capabilities`; add `config/routes.axum.rb`. Teach `inferred_name` the optional `app/` segment
   and `set :views, "app/views"`. No app-code change: `dsl-golden` must be byte-identical, parity and `dsl-bench`
   unchanged.
7. **Commands.** Extract `post_message` into `app/commands/publish_message.axum.rb` with `transaction` +
   `after_commit`, then the account, profile, message, boost and first-run writes. Each command gets its
   commit/rollback law; `post_message` drops from ~150 lines to ~8. `dsl-golden` shows the same `BEGIN`/`COMMIT`
   and statements, `dsl-bench` no regression, parity covers the broadcast/push behavior.

## Guardrails

- **Keep the refusals.** `locals:` is exact today, and that is why it is usable. `from:` must refuse a missing
  field, an extra field and a type a marker cannot write, with the view and the line.
- **Provenance in notices.** `N-VIEW-LOCALS` should name the capability and field as it names `layout_locals`
  and `page_locals` lines today, so “where did `user_id` come from” stays a compile-time answer.
- **Policy stays visible.** Implicit context is fine; implicit authorization is not. `capability :admin` should
  read as a policy statement at the controller or scope, not disappear into a base class.
- **Domain stays in models.** A capability is a cross-cutting concern with a record and a policy. `room_page`,
  `create_message`, transactions and broadcasts do not move into one.
- **Compile-time sugar only.** If a capability needs a runtime registry, a boxed filter list or a name→local map,
  it is the wrong design. The compiler expands it into the straight-line code the hand-written version emits.
- **A capability without laws is a comment.** Every capability ships at least one route law and one refusal; a
  change to a capability should touch exactly one law file and no controller.
- **One source per name.** Ambiguity stays refused, as it is for a route local versus a `view_local`.

## Open questions

- **Name.** `capability` for the bundle; `use_layer` stays outer middleware; `fragment` stays the file kind.
- **Scope.** A capability on a controller, a route-table `scope`, or a single route? All three are useful;
  propose controller and scope first, route options for data (`rate_limit:`, `cache:`).
- **Record visibility.** `from:` needs the render checker to see a record's typed fields; `record` already
  declares them, so this is a matter of passing that table into the render check.
- **Cache interaction.** A `from:` binding must enter the response-cache key exactly as an explicit `locals:`
  does, and a capability's `before` must keep running on cache hits as it does today.
- **`current` storage.** A typed request extension (readable from any filter) or a value provided through the
  filter chain (`provides:`, cheaper but action-scoped)? The cost model needs one answer that keeps `current`
  monomorphic and one query per request.
- **`after_commit` shape.** A block inside `transaction` (as sketched), a command-level declaration, or both? A
  retry on `SQLITE_BUSY` must not duplicate effects; they run once, on the final commit. Whether `after_rollback`
  is needed at all.
- **Command home.** `app/commands` for units that span models, model defs for single-model ones. Where the line
  sits decides how much new syntax `command` needs.
- **Capability coverage.** Should `axum_dsl test` refuse a capability with no `capability:` law, or warn? And are
  laws generic over a capability, or always app-specific? Propose app-specific first; a generic law needs a
  fixture route, which is a DSL feature of its own.
- **Migration syntax.** Compile capabilities as fragments first. That exercises the declarations and the order
  before the compiler grows the `from:` binding, and keeps each wave independently verifiable.
