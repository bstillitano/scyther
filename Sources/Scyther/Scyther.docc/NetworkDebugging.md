# Network Debugging

Inspect HTTP requests and responses to debug API interactions.

@Metadata {
    @PageColor(green)
}

## Overview

Scyther automatically intercepts all HTTP requests made through `URLSession` and logs them for inspection. This helps you debug API issues, verify request formatting, and understand network timing.

## Automatic Logging

Once Scyther is started, network logging is enabled automatically. All requests show up in the **Network Logs** section of the Scyther menu.

Each logged request includes:
- URL and HTTP method
- Request headers
- Request body (formatted for JSON)
- Response status code
- Response headers
- Response body
- Timing information
- cURL command for reproduction

### How Sessions Are Intercepted

Scyther intercepts a session by putting `HTTPInterceptorURLProtocol` at the front of its
configuration's `protocolClasses`. A session copies its configuration when it is created and never
reads it again, so this has to happen before the session exists — and a networking layer is often
built long before `Scyther.start()` runs, by a dependency container, an auth refresher or a
cross-platform client.

So the hooks are not installed by `start()`. A small Objective-C target, `ScytherBootstrap`,
installs them when the image loads, before any of the app's code runs. From then on every
configuration made with `.default`, `.ephemeral` or `.background(withIdentifier:)` carries the
interceptor, whatever order the app starts things in. `URLSession.shared` is covered separately,
by `URLProtocol.registerClass` in `start()`.

The interceptor is inert until Scyther starts: it declines every request while
``Scyther/isStarted`` is `false`. A session created before `start()` is therefore logged from the
moment `start()` returns, and requests it made before that are not.

- Note: The hooks run in **every** build, including App Store builds that never start Scyther. In
  those builds each configuration carries one extra protocol that declines every request. That is
  deliberate: it is what lets an App Store build that calls
  ``Scyther/start(allowProductionBuilds:)`` part-way through a session — behind an unlock code, say —
  log the sessions it created earlier.

To keep a session out entirely, include `String.noSwizzle` in its identifier:

```swift
let webhook = URLSessionConfiguration.default(withIdentifier: "webhook_\(String.noSwizzle)")
let upload = URLSessionConfiguration.background(withIdentifier: "upload_\(String.noSwizzle)")
```

## Viewing Requests

Open the Scyther menu and navigate to **Network Logs** to see all captured requests. Tap any request to see its full details.

### Request Details

The detail view shows:
- **Overview**: Method, URL, status code, duration
- **Request**: Headers and body sent to the server
- **Response**: Headers and body received from the server
- **cURL**: A ready-to-use cURL command to reproduce the request
- **Replays**: Every replay of this request currently in the log, and the deltas between them

## Accessing Network Data Programmatically

### Device IP Address

Get the device's public IP address:

```swift
let ip = await Scyther.network.ipAddress
print("Device IP: \(ip)")
```

### Streaming Requests

The `NetworkLogger` actor uses `AsyncStream` for real-time request updates:

```swift
// In your debug view
for await request in NetworkLogger.shared.requests {
    print("New request: \(request.url)")
}
```

## Filtering Requests

The Network Logs screen offers two ways to narrow the list, and they combine.

**Search** matches the URL, GraphQL operation name, status code, or HTTP method.

**Filter chips** sit above the list. Tap a chip to open a sheet with a multi-select checklist:

- **Method**: the HTTP methods present in the captured requests
- **Status**: 2xx success, 3xx redirect, 4xx client error, 5xx server error, or pending / no response
- **Host**: the request hosts present in the captured requests. An Include / Exclude segmented
  control in the list header decides whether the selected hosts are the only ones shown or the
  ones hidden
- **Type**: JSON, XML, HTML, Image, or Other, based on the detected response content type
- **API**: REST or GraphQL
- **GraphQL**: Query, Mutation, Subscription, or Batch / Unknown for GraphQL requests with no
  single operation type. REST requests never match a GraphQL selection
- **Duration**: under 100ms, 100ms to 500ms, 500ms to 1s, 1s to 3s, or over 3s. Requests still
  awaiting a response have no duration and never match a duration selection
- **Code**: the exact response status codes present in the captured requests
- **Recency**: last minute, 5 minutes, 15 minutes, or hour, measured from when the filter runs.
  Single-select, since each window contains the shorter ones

The icon-only chip at the start of the row opens a full-height Filters sheet that lists every
dimension, grouped into Request, Response, and Timing, with a summary of its selection. Tapping a row pushes that dimension's checklist, with
a Reset for that dimension alone; the root Filters screen offers Reset for everything.

Selections apply immediately behind the sheet. Chips combine with AND, values within a chip with
OR (Recency allows one value). Active chips are fully tinted and show the selected value when exactly one is chosen, or the
dimension name with a count when several are. A Reset button appears in each
sheet while it has a selection, and a red Clear chip appears in the bar whenever any filter is active.
Filters are held in memory for the current session only.

## Traffic Stats

The chart button in the Network Logs navigation bar opens **Traffic Stats**, which answers what is
slow, what is failing, and what was happening at the same time as what — computed from the
requests already in memory, so it adds nothing to the request path.

The screen describes the list you were looking at: search and filter chips narrow the requests
before the figures are computed, and the caption under the title says whether it is covering the
whole session (`8 requests`) or a slice of it (`21 of 340 requests`).

The summary reports the request count, how many were stubbed, failures and the failure rate,
pending requests, median and 95th percentile duration, bytes received, and the wall-clock span of
the session.

- **A stubbed response is counted but never measured.** A response a request override synthesised
  never left the device, so its duration measures Scyther rather than the server and its status
  code was authored rather than returned. Stubs are counted in *Requests* and *Stubbed* and left
  out of every duration, failure and byte total, and out of the host and endpoint breakdowns.
- **Percentiles use the nearest rank**, so every duration reported is one a request actually took
  rather than a number interpolated between two of them.
- **Below five completed requests there are no percentiles.** A median of three samples is noise,
  so the summary shows the fastest and slowest round trips instead.
- **Pending and failed are exclusive.** A load carries a response date whether or not a response
  arrived, so a request that ended in an error is a *failure* and a request that has not come back
  yet is *pending*. Neither is counted as a zero-duration completion, which would flatter every
  latency figure.
- **Elapsed leaves stubs out too.** A stub answered an hour after the last real request would
  otherwise report an hour of network activity that never happened.

The **waterfall** draws requests as bars on a shared seconds axis, labelled with their durations
and coloured by outcome. Bars that overlap were in flight at the same time; a staircase means the
calls were serialised. A request still in flight runs to the end of the axis, which is the moment
the chart was computed, because its real end is not yet known. A request that failed is drawn for
as long as it actually ran, in red, not as one still running.

The section itself draws `WaterfallOverviewStrip`, a `Canvas` that compresses every request
currently in the log into one short band, coloured by outcome and placed by when it happened. It
is not a preview of the seven most recent requests — it is the whole log, the same strip the full
page marks its window on, and its caption states the count, the span and how many distinct hosts
were touched rather than promising a summary. A touch that lands without travelling opens the full
page centred on the moment touched; a touch that travels is read as the start of a scroll and
passed through to the list the section sits in, which is what lets the section scroll normally
everywhere else on the strip.

**See all**, in the waterfall's section header, opens the same page too, but at the full span
rather than centred on anything — seen through a window the reader zooms and drags rather than
scrolled. Fitting the whole session into one screen width, or scrolling a plot wide enough not to,
are both a *scroll* answer to what is really a *zoom* problem: against a three hundred second log
of requests between thirty-two milliseconds and one and a half seconds either one either floors
every bar to the same sliver or hands the reader a plot thousands of points wide to pan by hand.

Opening at the full span, rather than pre-zoomed to something that looks more useful — the last
few seconds, say, or a fixed window around the newest request — is a deliberate choice, and the
one most likely to look like an oversight to whoever next touches this page. The page has no way
to know what "useful" means for a session it has not been told anything about: a five-minute gap
of quiet network between two bursts is exactly as informative as the burst itself, and defaulting
to the tail, or the busiest stretch, or anything narrower than everything, is a guess dressed up as
a courtesy. It is wrong exactly as often as it is right, and silently wrong in the one case that
matters most — the developer who opened the page looking for the gap, not the burst, and has no
way to tell from a pre-zoomed screen how much of the log they are not looking at. Opening honest
costs nothing a reader cannot fix with one pinch; arriving somewhere they did not ask to be is not
recoverable by looking harder at the screen in front of them. Tapping the Traffic Stats strip is
the one deliberate exception, and it does not contradict the rule: a tap names a moment, so the
page opens centred on it instead of guessing one, and it does so at a fraction of the span rather
than the full width — the reader chose where to start, so the page starts there. The rule is
against the page guessing; it was never against listening when the reader already said.

The page shows two things instead of a scroll. `WaterfallOverviewStrip` compresses the entire log
into one short band and marks the current window on it as a highlighted region; dragging the strip
moves that window anywhere in the log in a single gesture — on this page the strip only ever moves
the window, it never opens a request. Underneath it, a detail list holds only the requests whose
span intersects the window, so a row without a bar to show for it is structurally impossible, each
a tappable row running oldest first so time reads downward. A row shows its host stacked above its
path only when the log holds more than one distinct host; a single-host log never spends the width
repeating what every row already shares.

`WaterfallWindow`, a value type, owns the window's zoom limits and the clamping that keeps it
inside the span, so the strip's overlay and the detail list always agree on what "current" means.
Zoom is a pinch — `MagnificationGesture`, since the package's floor is iOS 16 and the newer
`MagnifyGesture` is not — on the detail list, which narrows or widens the window while holding its
centre still. The window can never be pinched narrower than the point at which the shortest
measured request in the log would draw under twenty-four points wide, so a pinch cannot zoom a
reader into a blur of a single hairline, and once that limit is reached the pinch and the strip's
adjustable action are both disabled rather than left to silently do nothing.
`.accessibilityAdjustableAction` on the strip puts the same zoom range behind VoiceOver's and
Switch Control's adjustable gesture, so reaching zoom never requires a pinch, and its accessibility
value announces how many of the log's requests the window holds after every change, so it never
leaves a VoiceOver user guessing whether anything happened.

A request already running when the window opens, or one that outlives it, is drawn clipped flush
to the window's edge rather than shrunk to fit — the clip reads as "continues", where a shrunk bar
would read as a request shorter than it actually ran. Tapping a row in the detail list opens that
request's details; tapping the strip itself never does. On this page dragging is the strip's only
job — opening a request from a tap is what the Traffic Stats section's strip does instead, and the
two are not the same gesture on the same control, they are different interactions the strip is
told which one it is in.

Both surfaces are handed the log's *filtered* requests, and the page's caption under the detail
list names how many of the log's total requests the current window holds.

The window, the highlighted region marking it on the strip, and the detail list belong to the full
page alone — the Traffic Stats section draws no detail rows of its own to share a row height or a
duration label with. What the two surfaces do share, through `WaterfallChartStyle`, is which
colour an outcome is drawn in: the strip's `Canvas`, the detail list's rows and the page's own
legend all read the same mapping, so a failed request is red wherever it is drawn, not red on one
surface and a slightly different red on another.

A bar too narrow to see is still drawn one point wide so that it can be found. That floor is a
minimum rendered *width*, not a minimum duration: it adds at most one point of ink however long
the session ran, and the bar's label still reports the real measurement. The page's own bars are
floored the same way by the clipping arithmetic that fits them into the window, so neither surface
ever draws a request that cannot be found.

**Slowest Endpoints** groups by `METHOD host/path`, dropping the query string and collapsing any
numeric or UUID path segment to `:id`, so `/users/1` and `/users/2` aggregate. A GraphQL operation
carries its name — `POST api.example.com/graphql (GetUser)` — because every operation in a GraphQL
API is posted to the same path and the name is what identifies the call. **By Host** puts the
worst offender first: most failures, then slowest median.

Stats describe the current session only — the log is an in-memory FIFO, so nothing persists across
launches.

## Exporting the Whole Log

The export button in the Network Logs navigation bar packages the requests currently shown into
`<App-Name>-Network-Log-<timestamp>.zip`, named after the host app. Search and filter chips narrow what is included.

The archive contains:

- `network-log.har`, a HAR 1.2 document readable by Charles, Proxyman, Chrome DevTools, and most
  HTTP tooling. Image bodies are embedded as base64.
- `requests/<index>-<METHOD>-<host>/` per request, holding `request.curl` and the raw request
  and response bodies when they exist.

The export sheet shows progress while the zip is built. A **Redaction** toggle, on by default,
replaces values whose header name, query parameter, JSON key, or form field looks sensitive
(authorization, tokens, cookies, passwords, API keys, sessions) with `REDACTED`, and scrubs
`Bearer` credentials and JWT-shaped strings wherever they appear. Redacted HAR files carry a
`log.comment` saying so. This is an attempt, not a guarantee: secrets under unusual names or in
formats the patterns do not cover pass through untouched.

Because the archive can include full headers, cookies, authentication tokens, and bodies, tapping
**Export** shows a sensitivity alert first; confirming opens the system share sheet. The file is
deleted when the sheet closes.

## Request Overrides

Logging shows what the app asked for and what came back. **Request Overrides** changes it:
reached from **Networking → Request Overrides**, it mocks endpoints, serves local files, rewrites
headers and degrades the connection, all without touching the app's networking code. The API type
is still called ``NetworkRule``, so an override in the UI is a rule in code.

Every override matches on HTTP method, host, path and query — an omitted facet places no
constraint, and host and path accept `*` as a wildcard. Overrides are evaluated top to bottom:

- The **first** matching mock or map local wins and short-circuits the network.
- The **first** matching condition supplies the latency, bandwidth ceiling and failure rate;
  they are not stacked from several overrides.
- **Every** matching header rewrite applies, and the **last** override to name a header decides
  what happens to it: a later `set` beats an earlier `remove` just as it beats an earlier `set`,
  and a later `remove` beats an earlier `set`. Header names are compared case-insensitively, so
  `Authorization` and `authorization` are one header. Within a single rewrite there is no order to
  appeal to, so `set` is applied before `remove` and a header named in both ends up removed.

Reordering the list is what changes precedence.

### What matching compares

- Method, host and path are compared **case-insensitively**. Query names are compared
  **case-sensitively**, because a query name is data rather than protocol.
- The path is compared **percent-encoded**, exactly as it travels on the wire. `%2F` is therefore
  not a separator — `/v1/a%2Fb` is one segment and does not satisfy a rule for `/v1/a/b` — and a
  path copied out of the log, out of a HAR, or off an address bar matches the request it came
  from. A path typed with a literal space will not.
- A **trailing slash is part of the path**: `/v1/users` and `/v1/users/` are different paths. Use
  `/v1/users*` to match both. A URL with no path at all, `https://api.example.com`, is matched as
  `/`.
- Every query pair listed must be present. A key that repeats is satisfied by **any** of its
  occurrences, so `page=2` matches `?page=1&page=2`, and a key present with no value — `?flag` —
  reads as an empty value. Values are compared percent-decoded.
- A pattern left **blank** places no constraint at all, exactly as leaving the facet out does. So
  does one that matches everything anyway — a path of `*` set to Wildcard, or `/` set to Contains
  — which is why the editor refuses to save either spelling. The engine still honours them for a
  rule built in code; the guard is on what the editor will save.

### The four actions

| Action | Type | What it does |
| --- | --- | --- |
| Mock Response | ``MockResponse`` | Answers with a status code, headers and a body typed into the editor, after an optional delay. |
| Map Local File | ``MapLocalFile`` | Answers with the contents of a file on the device, with a status code and `Content-Type`. |
| Rewrite Headers | ``NetworkHeaderRewrite`` | Sets and removes headers on the outgoing request, then lets it go to the network. |
| Network Condition | ``NetworkCondition`` | Adds latency, caps bandwidth, and fails a fraction of matching requests with a `URLError`. |

- Note: A condition's latency and a mock's delay are each capped at 30 seconds. Neither is waited
  out on the thread the request started on, so a delayed override cannot hold up traffic it does
  not match.
- Note: ``MockResponse/headers`` is a dictionary, so a mocked response cannot repeat a header
  name. Where a real response may send `Set-Cookie` more than once, only one value survives, and a
  HAR import keeps the last of the repeats.
- Note: ``MapLocalFile/path`` is **absolute**. A container path is not something anyone can type
  on a device, so it has to come from code or be picked in the editor, which copies the file into
  Scyther's own directory. A path that cannot be read fails safely — the request goes to the real
  network.

### Saving a captured request as a mock

The request details page carries a **Save as mock** button whenever the response came off the
wire. It opens the override editor pre-filled from the capture: matching that request's method,
host and path exactly, answering with its status code, its headers and its body. The query string
is left unconstrained, because the page number that happened to be captured is rarely what the
mock is about, and headers describing the wire encoding (`Content-Encoding`, `Content-Length`,
`Transfer-Encoding`) are dropped, because the stored body is the one `URLSession` already decoded.

The override arrives **disabled**. Nothing about the app's behaviour changes until it is switched
on, from the editor or with a swipe on the list.

A response an override synthesised cannot itself be saved as a mock — there would be nothing to
learn from the copy. Those rows are marked instead: the log list shows a pink **MOCKED** badge, and
the details page lists every override that shaped the request in an **Overrides** row — each one
tappable into its editor, and each one named even after the override behind it has been deleted. An override
that shapes a request without answering it — a header rewrite or a network condition — wears a
brown **OVERRIDDEN** badge instead. The two are exclusive: a mocked row never also reads as
overridden, because the mock is the stronger statement about what the app received.

### Importing a HAR file

**Import from HAR** in the list's add menu reads a HAR 1.2 document — one exported by Scyther, or
captured in Charles, Proxyman or Chrome DevTools — and turns each entry into a mock override named
`<METHOD> <path>`, matching that method, host and path. Entries are read one at a time, so a
capture full of the things a real HAR contains — an aborted request with no `response` object, a
multipart upload whose `postData` carries `params` and no `text`, an entry whose URL cannot be
parsed — costs those entries and nothing else. The alert reports both numbers: how many overrides
were added, and how many entries produced none.

A response body labelled `encoding: "base64"` is decoded even when it is wrapped across lines, as
Charles and other MIME-style encoders write it, and text that plainly is not base64 is taken as
the literal body it is rather than decoded into bytes that came from nowhere.

Every imported override arrives disabled, for the same reason a saved mock does: importing a
colleague's capture should never silently change what the app does.

### The master switch

**Enable Request Overrides**, at the top of the list, suspends every override at once without
deleting any of them. It is the fastest way to check whether a behaviour is the app's or an
override's. It is persisted, so it survives relaunch.

### Registering overrides from code

``Scyther/Network/rules`` is the programmatic entry point. It is `@MainActor`, like every other
Scyther singleton, and every member of it is inert until ``Scyther/start(allowProductionBuilds:)`` has run — which it
does not do on an App Store build. The code below can sit unguarded in `didFinishLaunching`: on a
release build it reads back nothing, writes nothing to preferences, and puts no file in the user's
container.

```swift
// Persisted: written to UserDefaults, listed in the menu, survives relaunch. The
// identifier is a constant, so relaunching updates this override rather than adding
// a second copy of it.
let emptyCart = UUID(uuidString: "6F0B0C3E-4C1E-4E3D-9C0B-0F5E7A9D2B41")!
Scyther.network.rules.add(
    .mock(id: emptyCart,
          name: "Empty cart",
          matching: .path("/api/cart"),
          returning: .json(#"{"items": []}"#))
)

// This launch only: never written to disk, listed read-only under "Registered in Code".
Scyther.network.rules.addTransient(
    .headers(name: "Staging auth",
             matching: .host("*.staging.example.com"),
             set: ["Authorization": "Bearer test-token"])
)

// Suspend everything without deleting anything.
Scyther.network.rules.isEnabled = false
```

- Important: ``NetworkRules/add(_:)`` **persists** the override and shows it in the menu, where a
  developer can edit or delete it. ``NetworkRules/addTransient(_:)`` does not: transient overrides
  live for the launch that registered them, are shown read-only, and cannot be reordered. Use the
  transient form for anything the app registers for itself, so it cannot outlive the run that
  created it.
- Important: Both are an upsert on ``NetworkRule/id``: an override whose identifier is already
  known replaces that override in place, and whatever body file it owned is reclaimed unless
  another override still points at it. Code that runs on every launch should pass a constant
  `id`, as the example above does. An override built without one gets a fresh identifier every
  time, so the same call in `didFinishLaunching` would store another copy of it on every launch.
- Important: An identifier lives in exactly one of the two lists. Registering a transient override
  under an identifier ``NetworkRules/add(_:)`` stored moves it across, and vice versa: the last
  registration wins outright.
- Note: ``MockResponse/json(_:status:delay:)`` writes nothing when it is built. Its bytes travel
  with the value and are written when the override holding it is stored, so a response that is
  never registered leaves nothing on disk. Both `add` methods return `false` when nothing was
  stored — Scyther is not running, or those bytes could not be written — rather than storing an
  override that would answer with the right status code and an empty body.

Transient overrides are evaluated after every persisted one, so a persisted mock on the same
endpoint takes precedence.

### Stubbing a UI test

Transient overrides make a UI test hermetic without a stub server:

```swift
// In the app, behind a launch argument the test sets.
if ProcessInfo.processInfo.arguments.contains("-UITestStubs") {
    Scyther.network.rules.isEnabled = true
    Scyther.network.rules.addTransient(
        .mock(name: "Profile",
              matching: .host("api.example.com", path: "/v1/profile", methods: ["GET"]),
              returning: .json(#"{"name": "Ada"}"#))
    )
    Scyther.network.rules.addTransient(
        .condition(name: "Slow uploads",
                   matching: .path("/v1/upload", methods: ["POST"]),
                   NetworkCondition(latency: 2, failureRate: 0.5))
    )
}
```

```swift
// In the test.
let app = XCUIApplication()
app.launchArguments += ["-UITestStubs"]
app.launch()
```

Because they are transient, the next launch starts clean — a stub left enabled by a failed run
cannot quietly break the next one.

- Note: Overrides only apply to traffic Scyther intercepts, which is `URLSession` traffic through
  a standard configuration. A custom `URLSessionConfiguration` that does not carry Scyther's
  `URLProtocol` bypasses overrides exactly as it bypasses logging.

## Network Conditioning

**Networking → Network Conditioning** degrades **every** request Scyther intercepts, which is what
Network Link Conditioner does without needing a Mac or a provisioning profile. The menu row shows
the active preset, or `Off`, so conditioning is never quietly on.

The screen carries a master switch, a preset picker — Wi-Fi, 4G, 3G, EDGE and a very bad network —
and the three numbers underneath it: a latency in seconds, a ceiling in KB/s, and a failure rate.
Picking a preset fills the three in; editing any of them makes the picker read Custom, because that
is what it now is. Custom is not something you pick: it is what the numbers read as when they match
no named link, so the picker lists it only while it is what they say.

The global condition is a **floor**, not an addition. A request override whose own condition
matches replaces it outright, so one endpoint can be conditioned differently — or barely at all —
while the rest of the app is on EDGE. An override that matches but carries no condition leaves the
global one in place.

It is off by default, persisted across launches, and separate from overrides: **Enable Request
Overrides** does not reach it, and neither does turning every override off.

- Note: A request the global condition slowed or failed carries the same brown `OVERRIDDEN` badge
  a per-override condition produces, so the log never shows a conditioned request as ordinary
  traffic. It is credited as **Network Conditioning** in the details page's **Overrides** row,
  which names it without offering a link — it is a screen rather than an override.

## Scythers own traffic

Scyther sends a few requests of its own: the menu's IP address lookup, and everything sent from
the replay editor. They are **logged like any other request** — seeing what the toolkit does is
useful — but Scyther does not let its own features interfere with them.

Two of the four are unconditional, because they are self-inflicted rather than preferences:

- **Breakpoints.** The toolkit was instrumenting itself: a breakpoint on `api.ipify.org` held the
  menu's own IP lookup; the held-request editor was presented over the menu, the presentation
  re-created the menu, the menu asked for the IP address again, and it was held again — one modal
  per second, stacking without limit, over the one screen that could have switched the breakpoint
  off. A held replay is the same shape one layer up: it stalls the editor that sent it.
- **Header rewrites.** The replay editor's promise is *this request, exactly as edited*, and a
  rewrite restoring a header the developer had just deleted contradicts it.

**Mocks and conditioning** are exempt by default but can be opted back into per request, which the
replay editor exposes as **Apply Request Overrides**. "Replay this captured request into the mock
I have just written" is a real workflow and the only way to fire a crafted request at an override
without waiting for the app to make the call itself. Nothing opts the IP lookup back in: the
opt-in travels on the request, and only Scyther can put it there.

Requests are marked with a `URLProtocol` property carrying a token minted once per launch, rather
than with a header. The mark never reaches the wire, so nothing is added to a request the
developer's server sees; it survives `mutableCopy()`, so it holds through the rewrite copy and the
breakpoint rebuild, and it is re-applied explicitly across a redirect, whose request the URL
loading system builds rather than copies. The host app's ordinary traffic cannot opt itself out,
because knowing the property key is not enough — the value has to be this launch's token. The
token is not a secret from code already running in the process, which can read any protocol
property it likes; the guarantee is that it is unguessable and does not survive a relaunch.

## Request Replay

The request details page carries a **Replay this request** button. It opens an editor pre-filled
from the capture and sends whatever is left there when the confirm button is tapped.

### The editor

- **Method** — a picker of the common verbs, plus **Other** for anything else.
- **URL** — validated live; the confirm button stays disabled while it will not parse into an
  absolute HTTP URL.
- **Headers** — one editable row per captured header, swipe-deletable, with an add row. Headers
  `URLSession` owns (`Content-Length`, `Host`, `Connection`) are shown but disabled and are
  dropped rather than sent. A duplicated header name travels as the comma-joined field HTTP
  defines rather than one row winning.
- **Body** — opens the same text editor the rest of the toolkit uses. The logger only writes a
  request body to disk when it decodes as UTF-8, so a binary body — a protobuf, a multipart
  upload — cannot be recovered from the capture. The editor says so on the row, in the section's
  footer and in a confirmation before sending, rather than quietly sending a request with no body;
  typing a body of your own retires the warning.
- **Apply Request Overrides** — a toggle, off by default, deciding whether mocks and network
  conditioning apply to this send. Breakpoints and header rewrites never do, whatever it says.

### What sending does

A replay goes out on an ordinary `URLSession` and comes back through the same interceptor as
traffic the app makes, which means:

- **it is logged as its own entry**, marked with a teal `REPLAY` badge, so a resent request can
  never be mistaken for one the app made;
- **no breakpoint holds it and no header rewrite touches it**, because a replay is a request
  Scyther itself composes and sends — see <doc:NetworkDebugging#Scythers-own-traffic>; and
- **mocks and conditioning apply only if you ask**, on the editor's **Apply Request Overrides**
  toggle. Off — the default — the replay goes to the server exactly as edited, which is what makes
  the comparison against the original mean something. On, a matching mock answers it and a
  matching condition shapes it, with both the `REPLAY` and `MOCKED` badges on the row and the
  override credited by name in the details page's **Overrides** row, exactly as before.

A response an override synthesised offers no replay button — the override would only synthesise
it again.

Any method outside `GET`, `HEAD` and `OPTIONS` warns in the editor and asks for confirmation in
an alert naming the method, because resending it can repeat whatever it changed. So does a replay
whose body could not be captured, and one aimed at a URL Scyther does not intercept — an ignored
host, or a scheme that is not HTTP — which would be sent and never appear in the log. The editor's
footer and the confirmation show the same list of warnings, so they cannot disagree.

### Comparing a replay to its original

Each replay records which capture it was built from. The original's page
lists its replays with each one's method, status and the signed duration and size deltas — replay
minus original — and each row links to that replay. The replay's own page links back through a
**Replayed from** row, or says the original is no longer in the log once it has been cleared.

Both sections follow the log as it changes, so a replay landing after the editor dismissed
appears without leaving the page.

A row whose exchange Scyther shaped says so, in the log's own badge words — `Original: MOCKED`,
`Replay: HELD OVERRIDDEN` — because a delta across a mocked, conditioned, held or edited exchange
measures the toolkit rather than the server.

- Note: Provenance is stamped per request and stripped from redirects, so the entry a redirect
  produces is a request in its own right rather than a second replay of the same original.

## Breakpoints

**Networking → Breakpoints** holds a matching request before it is sent, or a matching response
before the app sees any of it, and puts an editor in front of the developer so the exchange can be
read and changed in place.

This is the only feature in the toolkit that deliberately holds the app up, so its master switch
defaults to off and the menu row carries the count of breakpoints being applied.

### Setting one

A breakpoint is a ``NetworkRuleMatch`` — shared verbatim with request overrides — plus a stage and
a timeout.

- **Stage** — `Request`, `Response`, or `Both`, which holds twice.
- **Timeout** — 5 to 300 seconds, 60 by default, and not switchable off.

The editor refuses an unnamed breakpoint and one whose match names no endpoint: a match that
applies to everything would hold every request the app makes for the timeout each.

### Breaking on a captured request

The request details page carries a **Break on requests like this** button, beside **Save as mock**
and **Replay this request**. It opens the editor pre-filled from the capture, on the same matcher
a mock built from that page uses: the captured method, host and path exactly, with the query left
unconstrained, holding the request stage for the default minute.

It arrives enabled, where a mock arrives disabled. Enabling a mock changes what the app sees with
nothing on screen to say so; a breakpoint announces itself by stopping the request and putting a
screen in front of the developer. Nothing is written until the editor is confirmed either way.

The button is offered wherever the entry has a URL, including one an override answered — seeing
what the app sent to a stubbed endpoint is one of the things a breakpoint is for.

### When one fires

The editor is presented over the key window. One held exchange opens straight into its page;
several are listed. Each page shows the breakpoint's name, a countdown to the automatic continue,
and the exchange — method, URL, headers and body for a request, status, headers and body for a
response.

- **The confirm button** in the navigation bar — the icon-only checkmark Scyther uses to commit
  every editor — applies the edits and continues.
- **Continue Without Changes** passes the exchange on exactly as it arrived.
- **Abort** fails it with a chosen `URLError`, as though the network had produced it.
- **The timeout** continues it unchanged.

A held entry wears an indigo `HELD` badge in the log, and the log records what the app actually
saw — the edited exchange, not the original.

### What it does not do

- Nothing blocks. `startLoading()` returns while the request is held: the pause is a stored
  continuation on the coordinator's own queue, not a wait. Cancelling the request cancels the
  pause, and a cancelled pause delivers no client callbacks.
- A response breakpoint buffers the whole body, because a chunk already forwarded to the client
  cannot be recalled. Above 10 MB the pause is skipped and logged.
- Breakpoints report as off inside an XCTest process, so one left enabled can never hang CI, and
  are disabled on App Store builds with the rest of Scyther.
- A stubbed request is never held: the override answers it, so nothing goes in flight.
- Scyther's own requests are never held, at either stage — see <doc:NetworkDebugging#Scythers-own-traffic>.
- A pause taken while the app is not active is skipped and logged, because a held request the
  developer cannot see looks exactly like a hang. Only the newly taken pause is skipped: an
  exchange already open in the editor is not discarded for a glance at Control Centre or the app
  switcher. Anything still held when the app goes to the background is continued unchanged at that
  point, rather than waiting out its timeout out of sight.

## Exporting cURL Commands

Every request can be exported as a cURL command from the request details page. Tap the
share button in the top-trailing corner of the navigation bar, or the "Export cURL request"
row in the Developer Info section; both present the same system share sheet. This is useful for:
- Sharing with backend developers
- Testing in terminal
- Creating API documentation
- Debugging in tools like Postman

Example exported cURL:

```bash
curl -X POST 'https://api.example.com/users' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer token123' \
  -d '{"name": "John", "email": "john@example.com"}'
```

## Best Practices

### 1. Sensitive Data

Be aware that network logs may contain sensitive data like:
- Authentication tokens
- Personal information
- API keys

Scyther is automatically disabled in App Store builds to prevent exposure.

### 2. Large Responses

Very large response bodies are truncated for performance. If you need to inspect a large response, use the cURL export to replay the request.

### 3. Binary Data

Binary responses (images, files) are noted but not displayed inline. Use the cURL command to download them separately.

## Troubleshooting

### Requests Not Appearing

If requests aren't being logged:

1. Ensure `Scyther.start()` was called before the requests were made. The session itself may be
   older than `start()`; only the requests have to come after it.
2. Check that you're using `URLSession` (not custom networking)
3. Verify the app isn't an App Store build

### Custom URLSession Configurations

A configuration made with `.default`, `.ephemeral` or `.background(withIdentifier:)` carries
Scyther's protocol automatically. One whose `protocolClasses` the app replaces afterwards loses it,
and so does one whose identifier contains `String.noSwizzle`.

## See Also

- ``Network``
- ``NetworkRules``
- ``NetworkRule``

