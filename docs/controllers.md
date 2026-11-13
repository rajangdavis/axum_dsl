# Controllers

A `controller` groups routes the way a Rails controller does, with its own `before` filters and private methods.

```ruby
controller "Accounts::Bots" do
  before :ensure_can_administer
  before :set_bot_or_not_found, only: %i[edit destroy]

  get "/account/bots", action: :index do
    render :account_bots, locals: { bots: active_bots }
  end

  get "/account/bots/:id/edit", params: :BotPath, action: :edit do
    bot = set_bot
    render :account_bot_edit, locals: { bot: bot }
  end

  private

  def ensure_can_administer
    return head(403) unless administrator?
  end

  def set_bot
    account_bot(id: params[:id]) || raise("checked by set_bot_or_not_found")
  end
end
```

- **`def`** declares a method. A call to it is expanded inline: its statements compile where it is called, in a
  Rust block of their own, so its locals stay inside it. Its parameters are bound from the call's arguments
  (`deactivate_user(params[:id])`). A `return` in it answers the request, as a Rails `before_action`'s `head` or
  `render` halts the action. Used as a value (`bot = set_bot`), its last expression is the value. A def sees its
  parameters, `params[...]`, `current(...)`, settings, queries and helpers, but not the caller's locals. A
  filter's def also sees the values the filters declared before it provided to the same action.
- **Values are explicit.** A `before` filter without `provides:` guards: it answers the request or lets it through,
  and sets nothing a route reads. An action that needs a record calls the def that finds it (`bot = set_bot`), or
  a filter provides it (below).
- **Page and layout locals.** A controller may declare `page_locals do title = "Campfire" end` for the
  values its pages read, and `layout_locals do account_css = account_custom_styles end` for the values its
  layouts read (or a `view_local :name do ... end` for either): each is lowered in the routes whose render
  reads the name. A page local the layout reads is refused; a layout local may also feed a page. A controller
  entry wins over a top-level one. See [Views](views.md#layout-locals). Entries and action locals a view reads may
  be written `@x = ...` and read as `{{ @x }}` ([Views](views.md#instance-variables-x-and-x)).
- **`before :name, only: [...], provides: :room`** names a def run first in the controller's routes, in
  declaration order, after the top-level `before` filters (ApplicationController's). `only:`/`except:` name
  actions; without `provides:` the filter only guards (answers or passes on). With `provides:` the def's value
  is a local in the action and in later filters, so `before :set_room, provides: :room` is Rails'
  `before_action :set_room` plus `@room`. A filter's def, guarding or providing, reads the values provided by filters
  declared before it that run for the same action (never the action's own locals); a guard that reads a provided
  name its action does not get (the provider's `only:`/`except:` skips the action, or it is declared after the
  guard) is refused, naming the filter, the name and the action. A provided value read inside a `transaction`
  block is a plain local there: it is already computed. A top-level `before` is a layer and cannot provide.
- **Actions as defs.** `get "/rooms/:id", action: :show` with no block uses `def show` as the action; `action:` with
  a block is the inline action, named for the filters. A route with neither is refused. An action def takes no
  parameters (read inputs with `params[...]`).
- **Routes in a file.** A `fragment do` file, spliced with `use_dsl "routes.axum.rb"`, may hold routes with
  `controller: "Rooms", action: :show` and no block; the action def and its `before` filters are the
  controller's. The route table and the controller files stay in step at compile time.
- **Resources.** `resources :rooms, only: [:show], params: :RoomPath` in a routes file (or at the top level)
  declares the Rails resource routes and reaches this controller's defs, with its `before` filters. A member
  route captures `:id`, whose type is derived: the model declared with `table: :rooms` names the table, and its `id`
  column is the type (see "Path params" in dsl.md). `params:` is then only for the group the route also reads query or
  form fields from, and without a model for the table it still needs `field :id, :i64, in: :path`. `model: :User` names
  the model when the resource is not named for its table (`resources :bots, model: :User`). `params:` and `description:` also
  take a hash by action, `params: { edit: :BotPath, update: :BotUpdate }`, for a resource whose actions read different
  groups; a group a resource derives its `:id` for may leave that `field :id, ..., in: :path` line out. The resource also declares
  `room_path`/`rooms_path` and their `_url` forms. `scope path:` prefixes the routes in its block.
- **Top-level defs** (outside any controller, for example in a `models/` file) are shared by every route: model and
  concern methods. A controller's defs are its own, so two controllers may each have a `set_user`.
- `private` is a marker for the reader of the file, as in Rails; every def is private already.

Refused: `action:` outside a controller, a duplicate action, `only:`/`except:` naming an action the controller does
not have (or both on one filter), a filter naming no def, a `do ... end` filter inside a controller (that is a
top-level filter) and a top-level `before` without one, `provides:` on a top-level filter, two filters providing one
name to one action, a route with neither a block nor `action:`, an `action:` naming no controller def, an action def
with parameters, a duplicate def, a def with the name of a helper, a def that calls itself (directly or through
others), a call with the wrong number of arguments, a def used as a value that ends in `return` or `raise`, and a
controller name not shaped like a Rails one (`"Accounts::Bots"`).

`examples/controllers.axum.rb` has a controller with laws over its routes (see [Laws](laws.md)).

## Files: `controller do`, `model do`, `fragment do`

A file `use_dsl` includes holds one top-level call, which says what kind of file it is:

```ruby
# controllers/accounts/bots.axum.rb               # models/room.axum.rb
controller do      # "Accounts::Bots"             model do      # "Room"
  before :ensure_can_administer                     record :Room do ... end
  get "/account/bots", action: :index do ... end    query :room_for_user, ... sql: "..."
end                                                 def visible_rooms(user_id) ... end
                                                  end
```

- **`controller do`** takes its name from its path under `controllers/`, camelized with `::` between folders, as
  Rails names a controller after its file; `controller "Name" do` names one anywhere. It holds routes, `before :def`
  filters, params, defs, helpers and laws, and never SQL.
- **`model do`** takes its name the same way from `models/`. It holds records, `query`/`execute`, `current`, helpers,
  laws and model methods (defs, shared by every route). A route, a filter or a controller in it is refused.
- **`fragment do`** holds anything a file holds: a concern's named `before` filters and shared defs, settings, params.

The kind is checked by the signature table: a call a kind does not allow is refused with the kinds that do.
