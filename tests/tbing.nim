import cassette
import asyncdispatch, httpclient
from strutils import `%`

const URL_FMT = "https://www.bing.com/HPImageArchive.aspx?format=$#" &
                "&idx=0&n=1&mkt=en-US"

proc main() {.async.} =
  let client = newAsyncHttpClient()
  var cass = newAsyncCassetteClient(client, "bing_api.json",
                                    recordMode = NewEpisodes)
  let asJs = await cass.request(URL_FMT % ["js"], HttpGet)
  let asXml = await cass.request(URL_FMT % ["xml"], HttpGet)
  echo asJs.status
  echo asXml.status
  echo await asJs.body
  echo await asXml.body
  cass.close()
  cass.dispose()

waitFor main()
