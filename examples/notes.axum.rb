# typed: false
# SQL state (docs/database.md): a SQLite database, a record for the rows, and the SQL a route runs. The SQL is
# the text written below, run as written; the compiler checks the placeholders against `args:`, and the
# server checks every query against the database (and the columns against the record) once, as it starts.
# `typed: false` because Sorbet knows the DSL's calls (rbi/dsl.rbi) but not the query names this file declares.
# test/e2e_notes.sh drives it; examples/add.axum.rb holds port 8080, so this service takes 8084.
server "notes", version: "0.1.0"
set :port, 8084
# GET /notes.html renders notes/views/notes.html.
set :views, "notes/views"

# The file is notes.sqlite3 beside where the server runs, unless DATABASE_PATH names another.
database :sqlite, path: "notes.sqlite3", env: "DATABASE_PATH"

# The *.sql files in this folder are applied once each, in file-name order, as the server starts.
migrations "notes/db/migrate"

# A row of `notes`. A column that may be NULL is `optional: true` (nil-able in a body).
record :Note do
  field :id, :i64
  field :body, :string
  field :created_at, :string
  field :tag, :string, optional: true
end

query :recent_notes, args: { limit: :i64 }, returns: list(:Note), sql: <<~SQL
  SELECT id, body, created_at, tag FROM notes ORDER BY id DESC LIMIT :limit
SQL

query :find_note, args: { id: :i64 }, returns: :Note?, sql: "SELECT id, body, created_at, tag FROM notes WHERE id = :id"

query :add_note, args: { body: :string }, returns: :i64, sql: <<~SQL
  INSERT INTO notes (body, created_at) VALUES (:body, datetime('now')) RETURNING id
SQL

execute :delete_note, args: { id: :i64 }, sql: "DELETE FROM notes WHERE id = :id"

params :NewNote do
  field :body, :string, in: :form
end

params :NoteId do
  field :id, :i64, in: :path
end

post "/notes", params: :NewNote, description: "Add a note; the answer is its id" do
  add_note(body: params[:body]).to_s
end

get "/notes", description: "The newest notes, as JSON" do
  json(recent_notes(limit: 20))
end

get "/notes.html", description: "The newest notes, as a page" do
  render :notes, locals: { notes: recent_notes(limit: 20) }
end

get "/notes/:id", params: :NoteId, description: "One note, or 404" do
  note = find_note(id: params[:id])
  if note.nil?
    halt(404, "no such note")
  else
    json(note)
  end
end

delete "/notes/:id", params: :NoteId, description: "Delete a note; the answer is how many rows went" do
  delete_note(id: params[:id]).to_s
end
