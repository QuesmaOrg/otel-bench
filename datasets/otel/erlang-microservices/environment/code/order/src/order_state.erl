-module(order_state).
-behaviour(gen_server).

-export([start_link/0, create_order/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

create_order(Sku, Quantity, UserId) ->
    gen_server:call(?MODULE, {create, Sku, Quantity, UserId}).

init([]) ->
    {ok, #{orders => #{}, counter => 0}}.

handle_call({create, Sku, Quantity, UserId}, _From, State) ->
    #{orders := Orders, counter := Counter} = State,
    NewCounter = Counter + 1,
    ParcelNumber = list_to_binary("PARCEL-" ++ integer_to_list(NewCounter)),
    NewOrders = maps:put(ParcelNumber, #{sku => Sku, quantity => Quantity, user_id => UserId}, Orders),
    NewState = State#{orders := NewOrders, counter := NewCounter},
    {reply, ParcelNumber, NewState}.

handle_cast(_Msg, State) -> {noreply, State}.
handle_info(_Info, State) -> {noreply, State}.
