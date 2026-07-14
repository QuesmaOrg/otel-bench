-module(order_handler).
-behaviour(cowboy_handler).

-export([init/2]).

-define(STOCK_API_URL, "http://localhost:8081").

init(Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Json = jsx:decode(Body, [return_maps]),
    Sku = maps:get(<<"sku">>, Json),
    Quantity = maps:get(<<"quantity">>, Json),
    UserId = maps:get(<<"user_id">>, Json),

    Response = case decrease_stock(Sku, Quantity) of
        {ok, true} ->
            ParcelNumber = order_state:create_order(Sku, Quantity, UserId),
            #{<<"success">> => true, <<"parcel_number">> => ParcelNumber};
        {ok, false} ->
            #{<<"success">> => false, <<"error">> => <<"insufficient stock">>};
        {error, _} ->
            #{<<"success">> => false, <<"error">> => <<"stock service unavailable">>}
    end,

    Req = cowboy_req:reply(200,
        #{<<"content-type">> => <<"application/json">>},
        jsx:encode(Response),
        Req1),
    {ok, Req, State}.

decrease_stock(Sku, Quantity) ->
    Url = ?STOCK_API_URL ++ "/decrease",
    ReqBody = jsx:encode(#{<<"sku">> => Sku, <<"quantity">> => Quantity}),
    Headers = [{<<"Content-Type">>, <<"application/json">>}],
    case hackney:request(post, list_to_binary(Url), Headers, ReqBody, []) of
        {ok, 200, _RespHeaders, ClientRef} ->
            {ok, RespBody} = hackney:body(ClientRef),
            RespJson = jsx:decode(RespBody, [return_maps]),
            {ok, maps:get(<<"success">>, RespJson)};
        _ ->
            {error, unavailable}
    end.
