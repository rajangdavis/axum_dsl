# Query laws (docs/laws.md): the old SQL statement stays beside its relation port, and a law asserts that both
# return the same records in the same order, against the service's own database (point DATABASE_PATH at a
# disposable copy). Delete the old statement and the law once it holds.
server "querylaws", version: "0.1.0"
set :port, 8085

database :sqlite, path: "notes.sqlite3", env: "DATABASE_PATH"
migrations "notes/db/migrate"

table :notes do
  field :id, :i64
  field :body, :string
  field :created_at, :string
  field :tag, :string, optional: true
end

record :Note do
  field :id, :i64
  field :body, :string
  field :created_at, :string
  field :tag, :string, optional: true
end

# The old statements, as SQL.
query :recent_notes_sql, args: { limit: :i64 }, returns: list(:Note), sql: <<~SQL
  SELECT id, body, created_at, tag FROM notes ORDER BY id DESC LIMIT :limit
SQL

query :find_note_sql, args: { id: :i64 }, returns: :Note?, sql: "SELECT id, body, created_at, tag FROM notes WHERE id = :id"

# The same statements as relations; the routes use these.
model :Memo, table: :notes do
  query :recent_notes, args: { limit: :i64 }, returns: list(:Note) do
    order(id: :desc).limit(arg(:limit))
  end

  query :find_note, args: { id: :i64 }, returns: :Note? do
    where(id: arg(:id))
  end
end

params :Page do
  field :limit, :i64, min: 0, max: 50
end

params :NoteId do
  field :id, :i64, in: :path, min: 0, max: 100
end

get "/notes", description: "The newest notes, as JSON" do
  json(recent_notes(limit: 20))
end

get "/notes/:id", params: :NoteId, description: "One note, or 404" do
  note = find_note(id: params[:id])
  if note.nil?
    halt(404, "no such note")
  else
    json(note)
  end
end

law :recent_notes_match_their_sql, forall: :Page, cases: 32 do |limit|
  recent_notes_sql(limit: limit) == recent_notes(limit: limit)
end

law :find_note_matches_its_sql, forall: :NoteId, cases: 32 do |id|
  find_note_sql(id: id) == find_note(id: id)
end
