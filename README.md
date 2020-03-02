Envoy Timeouts
===

I created this repository to demonstrate and document Envoy timeouts.
Running Envoy in a production environment can cause unexpected HTTP status codes being returned by the proxy.
When moving from a setup with services connecting to each other without a proxy it might be a challenge when you start seeing unexpected errors.

This guide is intended for HTTP/1.1 users. It's a simple request/response model, which can serve as the basis in understanding how HTTP/2 can behave. Check HTTP/2 section at the very end.

# Understanding Envoy timeouts

When client A connects to a server B without a proxy, there's just one connection.
If B's HTTP server is down or misbehaving it can cause:

* connection timeouts when establishing the connection (connection timeout)
* socket timeouts when sending / receiving data (request/response idle timeout)
* connection closed (connection idle timeout)
* 408 HTTP errors to signify the client did not send the request in time (client request timeout)
* 503 HTTP errors to signify the server can't handle the traffic
* HTTP client errors in A when B doesn't fulfill the request in time (request timeout)

When Envoy is in use to form a Service Mesh, we're dealing with possibly many connections.

With proxy in between, there's one more HTTP error to consider:

* 504 Gateway Timeout when a request to the target service takes too long from proxy's perspective

In the basic configuration we'd have the following options:

* A -> A's Envoy -> B (only A uses proxy for outgoing traffic)
* A -> B's Envoy -> B (only B uses proxy for incoming traffic)
* A -> A's Envoy -> B's Envoy -> B (both parties use Envoy)

Each of the arrows represents an HTTP connection. All of these connections are subject to possible timeout issues.

It's best to think about this as either the client or the server's owner and debug the appropriate Envoy.

## How Envoy times out

One thing to note is that each Envoy uses two connections for a particular request. One for the client and one for the target server.

* In case of A's Envoy it's "downstream" is A's HTTP client, and it's "upstream" is either B's HTTP server or B's Envoy
* In case of B's Envoy it's "downstream" is A's HTTP client or A's Envoy and it's "upstream" is B's HTTP server.

Having that in mind we can now think of just one Envoy and it's configurations:

* someone requesting data via Envoy is called "downstream"
* someone providing data to Envoy's client is called "upstream"

Let's go through possible failure scenarios with:

* failure description
* configuration handles
* timeout outcome
* diagnosing steps

### Connection timeout to Envoy

**Description:**
Network misconfiguration or Envoy is not accepting requests.

**Configuration:**
Configure the HTTP client to reconnect / fix Envoy.

**Timeout Outcome:**
HTTP client errors.

**Diagnosing:**
Check your client's logs.

### Connection idle timeout to Envoy

**Description:**
When no requests are sent by the client, Envoy will simply close the connection. From the client's perspective this situation is handled by the HTTP client which is in use. The client can establish a new connection before sending requests and manage them in the pool or requests will fail.

**Configuration:**
Envoy allows configuring connection idle timeout per downstream listener and it's corresponding HttpConnectionManager in the
[`common_http_protocol_options.idle_timeout`](https://www.envoyproxy.io/docs/envoy/latest/api-v2/api/v2/core/protocol.proto#envoy-api-msg-core-httpprotocoloptions).

**Timeout Outcome:**
Closed connection from client.

**Diagnosing:**
`http.{listener_name}.downstream_cx_idle_timeout` metric will increase.

### Request idle timeout to Envoy

**Description:**
When an initiated request is being sent too slowly in a way that even the headers are not delivered at required intervals, Envoy will respond with a 408 error code.

**Configuration:**
The global [`stream_idle_timeout`](https://www.envoyproxy.io/docs/envoy/latest/api-v2/config/filter/network/http_connection_manager/v2/http_connection_manager.proto#envoy-api-field-config-filter-network-http-connection-manager-v2-httpconnectionmanager-stream-idle-timeout)
handles this case.

**Timeout Outcome:**
408 error code.

**Diagnosing:**
`http.{listener_name}.downstream_rq_idle_timeout` metric will increase.

### Request timeout to Envoy

**Description:**
When the client has initiated the request by completing all headers but is sending the request too slowly or the server is consuming it too slowly, Envoy will respond with a 408 error code.

**Configuration:**
HTTPConnectionManager's [`request_timeout`](https://www.envoyproxy.io/docs/envoy/latest/api-v2/config/filter/network/http_connection_manager/v2/http_connection_manager.proto#envoy-api-field-config-filter-network-http-connection-manager-v2-httpconnectionmanager-stream-idle-timeout)
manages this situation.

**Timeout Outcome:**
408 error code.

**Diagnosing:**
`http.{listener_name}.downstream_rq_timeout` metric will increase.

### Connection timeout to target server

**Description:**
When Envoy can't establish a connection to the target server it will respond with a 503 status code.

**Configuration:**
The setting for [cluster's `connect_timeout`](https://www.envoyproxy.io/docs/envoy/latest/api-v2/api/v2/cluster.proto)

**Timeout Outcome:**
503 status code (with message `no healthy upstream* Closing connection 0`).

**Diagnosing:**
`cluster.{cluster_name}.upstream_cx_connect_timeout` metric will increase or `cluster.{cluster_name}.upstream_cx_connect_fail` when connection is refused.

### Connection idle timeout to target server

**Description:**
This situation simply closes the connection to the target server when there are no active requests and their responses flowing. Envoy simply closes the connection. However, this might cause issues such as the next section if there's another Envoy connecting to this one. To prevent errors it's best to specify this timeout lower than the target server's idle timeout for incoming connections.

**Configuration:**
Upstream cluster's [`common_http_protocol_options.idle_timeout`](https://www.envoyproxy.io/docs/envoy/latest/api-v2/api/v2/core/protocol.proto#envoy-api-msg-core-httpprotocoloptions)
regulates this timeout.

**Timeout Outcome:**
Closed connection to the target server. Upon next request, a new connection is established.

**Diagnosing:**
`cluster.{cluster_name}.upstream_cx_idle_timeout` metric will increase. Also, `cluster.{cluster_name}.upstream_cx_destroy_local` will increase and possibly.

### Connection closed by target server

**Description:** 
If the target server closes idle connections eagerly this might lead to a request being directed to a connection that is in the process of being closed. Envoy will respond witha 503 error to the client.

**Configuration:**
Configure the idle timeout for outgoing connections (above section).

**Timeout Outcome:**
Intermittent 503 errors.

**Diagnosing:**
`cluster.{cluster_name}.upstream_cx_destroy_remote` metric will increase. If also `cluster.{cluster_name}.upstream_cx_destroy_remote_with_active_rq` increases this might signify 503 errors were returned to clients.

### Request or response idle timeout to target server

**Description:**
When request data from the client or response from the target server is arriving too slowly and there is no data sent over the connection, Envoy will respond with a 408 HTTP status.

**Configuration:**
One timeout is a global "stream idle timeout" which is applied globally
[per listener](https://www.envoyproxy.io/docs/envoy/latest/api-v2/config/filter/network/http_connection_manager/v2/http_connection_manager.proto#envoy-api-field-config-filter-network-http-connection-manager-v2-httpconnectionmanager-stream-idle-timeout)
to all requests.
A specific timeout can be configured per route and overrides the global. A route is an HTTP setting applied to the listener's HttpConnectionManager's filter which performs routing to the target service. The idle_timeout is configured via [Route Action setting](https://www.envoyproxy.io/docs/envoy/latest/api-v2/api/v2/route/route_components.proto#route-routeaction).

**Timeout Outcome:**
408 status from Envoy.

**Diagnosing:**
Metric `http.{listener_name}.downstream_rq_idle_timeout` will increase.

### Request or response timeout to target server

**Description:**
When the client has successfully transferred the entire request to Envoy then if the response doesn't arrive within the specified time Envoy will cancel the request and respond with a 504 status code.

**Configuration:**
The route [timeout](https://www.envoyproxy.io/docs/envoy/latest/api-v2/api/v2/route/route_components.proto#route-routeaction) configured per route is applied once the entire request was received from the client. If data is either slowly consumed by the client or slowly sent by the server this timeout will cause a 504.

**Timeout Outcome:**
504 error code.

**Diagnosing:**
The metric `cluster.{cluster_name}.upstream_rq_timeout` will increase.

# Examples

Each example is self contained in it's own directory. Remember to run the `cleanup.sh` script at the end as port allocation colisions might occur if you don't destroy the docker container.

* `build.sh` prepares the docker container with the necessary Envoy setup
* `run.sh` runs the container
* `query.sh` issues one or more HTTP requests to demonstrate the case
* `stats.sh` displays the interesting statistics from Envoy to confirm what happened
* `cleanup.sh` kills the docker container

## 408 from Envoy

The Envoy setup contains two listeners to imitate a slow rersponding target service:

* The first one imposes a route `idle_timeout: 2s` which is a request/response idle timeout. It directs traffic to the second listener's port.
* The second listener defines a static response route, returning a simple string and status `200`.

The first listener's route declares a cool feature of Envoy:

* A fault injection filter, which adds `5s` delay before directing traffic to the second listener's port.

As a result, the first listener causes a `408` HTTP status.

Try commenting out the route `idle_timeout` and notice that after `5s` the `HTTP 200` response arrives properly.

*Note: we can't simply use one listener because the fault injection happens before directing traffic to a specified cluster. And then at that cluster's target listener, we can specify a static route response. If defined at the first route, there would be no delay imposed.*

## 503 from Envoy

This one is not an obvious case of target service being unreachable. Instead, this example shows an intermittent 503 error code returned by Envoy when the target service is proactively closing idle connections.

To demonstrate this case, two listeners were necessary:

* The first one simply points to the second.
* The second listener one defines a connection `idle_timeout: 0.5s`

The second listener is directing traffic to `google.com`, which returns actual HTML content in order to have some actual data flowing so that the requests take a bit of time. This will hopefully highlight the problem quite quickly. As this is querying an actual web server, do make sure you have a good connection. If Envoy encounters problems connecting to `google.com` this will also appear as 503s.

The `query.sh` script runs `curl localhost:10000` in a loop and sleeps for `650ms`.

You can fiddle with the sleep time, but after 10-20 tries a `503` should pop up in the output of the `query.sh` command. This is a problem that can happen when your traffic is not very heavy but tends to happen at periods around the time that the target server configured their connection idle timeout.

What can you do to fix it? Try commenting out the connection `idle_timeout: 0.3s` setting in `target_proxy_cluster` section in `envoy.yaml`, do a cleanup, build and run. It should eliminate the 503s when you run `query.sh` again.

*Note 1: This example only works on Mac OS's `sleep`, as Linux only accepts entire seconds as parameter.*

*Note 2: We're using two listeners because the second one closes the connections proactively. And Envoy as the first listener, being an L7 proxy, generates a 503 HTTP error to signify the remote part closed the connection while a request was being sent.*

## 504 from Envoy

In this setup we'll be trying to connect to `google.com`. We'll use two listeners:

* The first one imposes a route `timeout: 2s` which is a request/response timeout. It points to the second listener's port.
* The second listener points to `google.com` and also applies the fault injection filter to that route with a delay of `5s`.

As a result, the first listener responds with a `504` HTTP error code.

*Note: as with the `408` example, this setup is also using two listeners. The request timeout defined per route is launched only after the fault injection filter is exercised. Why? Because filters are applied in order and the `envoy.router` filter is always applied last.*

# HTTP/2

All of the above explanations were meant for HTTP/1.1. For HTTP/2 imagine the request/response from HTTP/1.1 were called a stream. And streams could have more than one request and more than one response, but could end the stream when done. In this case all timeouts regarding request/response idle timeouts stretch the entire stream, not just a particular request or response. Request and response idle timeouts still apply the same way. And connection timeouts apply when no stream is active. Entire request timeouts (defined per route) [are not recommended by Envoy developers](https://www.envoyproxy.io/docs/envoy/latest/faq/configuration/timeouts#route-timeouts) as they are not compatible with streaming responses (which may never end).
