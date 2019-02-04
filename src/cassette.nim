import json
import httpcore, httpclient
import asyncnet, asyncdispatch

from times import format, now
from streams import newStringStream

## Record and replay your HTTP sessions!
##
## All the HTTP requests made via a ``CassetteClient`` (or its asynchronous
## counterpart ``AsyncCassetteClient``) are first looked up in a archive (called
## *cassette*) and, if a matching request is found, its content is returned
## instead of hitting the network. If the request is not yet present in the
## cassette file it will be added once it is fetched before returning it as if
## nothing happened.
##
## Example
## -------
##
## .. code-block::
##    :file: tests/tbing.nim
##    :test:

# TODO (in order of decreasing priority)
# Sanitize the requests
# Make the matching configurable
# Expiration mechanism for the cached interactions
# Option to store the body base64-encoded

const
  TIME_FMT = "yyyy-MM-dd\'T\'HH:mm:ss"

type
  InteractionReq = object
    url: string
    headers: HttpHeaders
    body: string
    `method`: string

  InteractionResp = object
    version: string
    status: string
    headers: HttpHeaders
    body: string

  Interaction = object
    recordedAt: string
    request: InteractionReq
    response: InteractionResp

  CassetteError* = object of CatchableError

  CassetteRecordMode* = enum ## \
    ## Specifies how the content of the cassette is handled and updated:
    ##
    ## - ``Once``: Replay previously recorded interactions but do not record \
    ## new ones if a cassette file is already present. \
    ## In other words once a cassette is written to disk you can't add more \
    ## interactions. \
    ## \
    ## This is the default recording mode.
    ## - ``NewEpisodes``: Replay previously recorded interactions and record \
    ## new ones.
    ## - ``None``: Replay previously recorded interactions and raise an \
    ## exception for any new request.
    ## - ``All``: Record any new interaction but never replay previously \
    ## recorded ones.
    Once
    NewEpisodes
    None
    All

  CassetteClientBase[T] = ref object
    innerClient*: T
    recordMode: CassetteRecordMode
    filePath: string
    dirty, wasBlank: bool
    interactions: seq[Interaction]

  CassetteClient* = CassetteClientBase[HttpClient] ## \
    ## A synchronous CassetteClient, roughly behaving as a ``HttpClient``.
  AsyncCassetteClient* = CassetteClientBase[AsyncHttpClient] ## \
    ## An asynchronous CassetteClient, roughly behaving as a \
    ## ``AsyncHttpClient``.

template log(msg: varargs[untyped]) =
  when defined(cassetteLog):
    echo msg

template raiseErr(msg: string) =
  raise newException(CassetteError, msg)

proc `%`(h: HttpHeaders): JsonNode =
  result = newJObject()
  if h != nil:
    for k, v in h.pairs():
      result[k] = newJString(v)

proc toHttpHeaders(n: JsonNode): HttpHeaders =
  result = newHttpHeaders()

  for k, v in n.pairs():
    result[k] = v.getStr()

proc toCassette(n: JsonNode): Interaction =
  doAssert n.kind == JObject

  result.recordedAt = n["recordedAt"].getStr()

  let reqObj = n["request"]
  result.request.url = reqObj["url"].getStr()
  result.request.headers = toHttpHeaders(reqObj["headers"])
  result.request.body = reqObj["body"].getStr()
  result.request.method = reqObj["method"].getStr()

  let respObj = n["response"]
  result.response.version = respObj["version"].getStr()
  result.response.headers = toHttpHeaders(respObj["headers"])
  result.response.body = respObj["body"].getStr()
  result.response.status = respObj["status"].getStr()

proc dispose*(c: CassetteClient | AsyncCassetteClient) =
  ## Write back the list of interactions to the cassette file.
  if not c.dirty:
    return

  writeFile(c.filePath, (%c.interactions).pretty())

proc finalizeCassetteClient(c: CassetteClient | AsyncCassetteClient) =
  c.dispose()

proc newCassetteClientAux[T](httpClient: T; cassetteFile: string;
                             recordMode: CassetteRecordMode = Once):
                            CassetteClientBase[T] =
  ## Creates a new ``CassetteClient`` wrapping the given ``HttpClient`` (or
  ## ``AsyncCassetteClient``) object.
  new(result, finalizeCassetteClient)

  try:
    let jsonData = parseFile(cassetteFile)

    result.interactions = newSeqOfCap[Interaction](jsonData.len)
    for i in 0 ..< jsonData.len:
      result.interactions.add(toCassette(jsonData[i]))
  except JsonParsingError as e:
    raiseErr("Invalid json data: " & e.msg)
  except IOError:
    # We didn't load anything, the cassette was blank
    result.wasBlank = true

  result.filePath = cassetteFile
  result.innerClient = httpClient
  result.recordMode = recordMode

proc newCassetteClient*(httpClient: HttpClient; cassetteFile: string;
                        recordMode: CassetteRecordMode = Once):
                       CassetteClient =
  ## Wrap a ``HttpClient`` client.
  result = newCassetteClientAux[HttpClient](httpClient, cassetteFile, recordMode)

proc newAsyncCassetteClient*(httpClient: AsyncHttpClient; cassetteFile: string;
                             recordMode: CassetteRecordMode = Once):
                            AsyncCassetteClient =
  ## Wrap a ``AsyncHttpClient`` client.
  result = newCassetteClientAux[AsyncHttpClient](httpClient, cassetteFile,
                                                 recordMode)

proc close*(c: CassetteClient | AsyncCassetteClient) =
  ## Close any connection held by the client.
  c.innerClient.close()

proc headers*(c: CassetteClient | AsyncCassetteClient): var HttpHeaders =
  ## Small wrapper function to let the user read or modify the inner client
  ## `headers` field.
  c.innerClient.headers

proc request*(c: CassetteClient | AsyncCassetteClient; url: string;
              httpMethod: string; body: string = ""; headers: HttpHeaders = nil):
             Future[Response | AsyncResponse] {.multisync.} =
  var foundIdx = -1

  # Search in the cassette before accessing the network
  for i, inter in c.interactions:
    if inter.request.url == url and inter.request.method == httpMethod:
      foundIdx = i
      break

  case c.recordMode:
  of Once:
    if foundIdx < 0 and not c.wasBlank:
      raiseErr("Cannot store another interaction in Once mode")
  of NewEpisodes:
    discard
  of None:
    if foundIdx < 0:
      raiseErr("Cannot store another interaction in None mode")
  of All:
    # Force recording
    foundIdx = -1

  if foundIdx != -1:
    log("Request found in cassette...")

    let inter = c.interactions[foundIdx]

    new(result)
    result.version = inter.response.version
    result.status = inter.response.status
    result.headers = inter.response.headers

    when c is CassetteClient:
      result.bodyStream = newStringStream(inter.response.body)
    else:
      result.bodyStream = newFutureStream[string]("request")
      waitFor result.bodyStream.write(inter.response.body)
      result.bodyStream.complete()
  else:
    log("Request not found in cassette...")

    when c is CassetteClient:
      result = c.innerClient.request(url, httpMethod, body, headers)
      let bodyContent = result.body
    else:
      result = await c.innerClient.request(url, httpMethod, body, headers)
      let bodyContent = await result.body

    var newInteraction = Interaction(
      recordedAt: now().format(TIME_FMT),
      request: InteractionReq(url: url,
                              headers: headers,
                              body: body,
                              `method`: httpMethod),
      response: InteractionResp(version: result.version,
                                status: result.status,
                                headers: result.headers,
                                body: bodyContent)
    )

    c.interactions.add(newInteraction)
    c.dirty = true

proc request*(c: CassetteClient | AsyncCassetteClient; url: string;
              httpMethod: HttpMethod; body: string = "";
              headers: HttpHeaders = nil): Future[Response | AsyncResponse]
             {.multisync.} =
  result = await c.request(url, $httpMethod, body, headers)
