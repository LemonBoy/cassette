Cassette
========

Record and replay your HTTP sessions!

**Note**: The project is in its early development stage, use at your own risk
(and, of course, PR are welcome).

The documentation is available by doing `nim doc src/cassette.nim`, you'll find
a file named `cassette.html` in the `src` folder.

Why?
====

- Because you want your tests to be deterministic (and fast)!
- Because you don't want to hammer the remote server during the early
  prototyping stages of your app/library!

How?
====

Here's a simple example that shows how to fetch Bing's image of the day in both
json and xml format and store them in a cassette file named `bing_api.json`.

Once the cassette is ready the requested URLs will be fetched from that instead
of hitting the network.

```nim
import cassette
import asyncdispatch, httpclient

const URL_FMT = "https://www.bing.com/HPImageArchive.aspx?format=$#" &
                "&idx=0&n=1&mkt=en-US"

proc main() {.async.} =
  let client = newAsyncHttpClient()
  var cass = newAsyncCassetteClient(client, "bing_api.json")
  let asJs = await cass.request(URL_FMT % ["js"], HttpGet)
  let asXml = await cass.request(URL_FMT % ["xml"], HttpGet)
  echo asJs.status
  echo asXml.status
  echo await asJs.body
  echo await asXml.body
  cass.dispose()

waitFor main()
```

Ideally `CassetteClient` (and `AsyncCassetteClient`) should behave as a plain
old `HttpClient` (and `AsyncHttpClient`).

Acknowdlegments
===============

The [vcr](https://github.com/vcr/vcr) project inspired me to turn a half-assed
mocking harness into a pretentious half-assed library.
