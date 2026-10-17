# typed: true
# A fragment: its one top-level call is `fragment do ... end`, holding what a file holds.
fragment do
  params :Pair do
    field :a, :i32, in: :query
    field :b, :i32, in: :query
  end

  params :Who do
    field :name, :string, in: :query
  end
end
