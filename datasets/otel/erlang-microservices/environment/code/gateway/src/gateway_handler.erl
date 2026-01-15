-module(gateway_handler).
-behaviour(cowboy_handler).

-export([init/2]).

-define(STOCK_API_URL, "http://localhost:8081").
-define(ORDER_API_URL, "http://localhost:8082").

init(Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Json = jsx:decode(Body, [return_maps]),
    Sku = maps:get(<<"sku">>, Json),
    Quantity = maps:get(<<"quantity">>, Json),
    UserId = maps:get(<<"user_id">>, Json),

    Response = case check_stock(Sku, Quantity) of
        {ok, true} ->
            case create_order(Sku, Quantity, UserId) of
                {ok, OrderResponse} ->
                    OrderResponse;
                {error, _} ->
                    #{<<"success">> => false, <<"error">> => <<"order service unavailable">>}
            end;
        {ok, false} ->
            #{<<"success">> => false, <<"error">> => <<"product not available">>};
        {error, _} ->
            #{<<"success">> => false, <<"error">> => <<"stock service unavailable">>}
    end,

    Req = cowboy_req:reply(200,
        #{<<"content-type">> => <<"application/json">>},
        jsx:encode(Response),
        Req1),
    {ok, Req, State}.

check_stock(Sku, Quantity) ->
    Url = ?STOCK_API_URL ++ "/check",
    ReqBody = jsx:encode(#{<<"sku">> => Sku, <<"quantity">> => Quantity}),
    Headers = [{<<"Content-Type">>, <<"application/json">>}],
    case hackney:request(post, list_to_binary(Url), Headers, ReqBody, []) of
        {ok, 200, _RespHeaders, ClientRef} ->
            {ok, RespBody} = hackney:body(ClientRef),
            RespJson = jsx:decode(RespBody, [return_maps]),
            {ok, maps:get(<<"available">>, RespJson)};
        _ ->
            {error, unavailable}
    end.

create_order(Sku, Quantity, UserId) ->
    Url = ?ORDER_API_URL ++ "/create",
    ReqBody = jsx:encode(#{<<"sku">> => Sku, <<"quantity">> => Quantity, <<"user_id">> => UserId}),
    Headers = [{<<"Content-Type">>, <<"application/json">>}],
    case hackney:request(post, list_to_binary(Url), Headers, ReqBody, []) of
        {ok, 200, _RespHeaders, ClientRef} ->
            {ok, RespBody} = hackney:body(ClientRef),
            {ok, jsx:decode(RespBody, [return_maps])};
        _ ->
            {error, unavailable}
    end.
