import
  std/[algorithm, json, locks, monotimes, nativesockets, options, os,
    strutils, tables, times],
  supersnappy,
  bitworld/client as bitworldClient, bitworld/profile, bitworld/spriteprotocol,
  bitworld/runtime,
  curly, mummy,
  sim, global, glory, replays, replay_codec as ctfReplayCodec, broadcast,
  replay_runtime, events, wire_constants,
  control, directives, baselines, decide, mux,
  ../shell/[body, body_map, episode, ingress, outbound,
    standing_order, transport, view],
  ../shell/dispatch, ../shell/packets, ../shell/replay_records, ../shell/seats,
  hosted,
  ../shell/types,
  ../shell/vote_packets as votePackets

when defined(posix):
  from std/posix import SHUT_RDWR, shutdown

type
  PlayModuleUploadConsumer* = proc(
    websocket: WebSocket,
    seat: int,
    generation: uint64,
    packet: ModuleUploadPacket,
  ) {.gcsafe.}

  PlayCallConsumer* = proc(
    websocket: WebSocket,
    seat: int,
    generation: uint64,
    packet: PlayCallPacket,
  ) {.gcsafe.}

  PlayStatusAckConsumer* = proc(
    websocket: WebSocket,
    seat: int,
    packet: StatusAckPacket,
  ): PlayIngressFeedback {.gcsafe.}

  PlayLobbyChatConsumer* = proc(
    websocket: WebSocket,
    seat: int,
    packet: LobbyChatSendPacket,
  ) {.gcsafe.}

  PlayBallotCastConsumer* = proc(
    websocket: WebSocket,
    seat: int,
    packet: BallotCastPacket,
  ) {.gcsafe.}

  PlaySeatKickConsumer* = proc(
    seat: int,
  ): seq[ShellAnnotation] {.gcsafe.}

  PlayReceiveConsumers = object
    moduleUpload: PlayModuleUploadConsumer
    playCall: PlayCallConsumer
    statusAck: PlayStatusAckConsumer
    lobbyChat: PlayLobbyChatConsumer
    ballotCast: PlayBallotCastConsumer
    kick: PlaySeatKickConsumer

  WebSocketSocketFields = object
    server: Server
    clientSocket: SocketHandle
    clientId: uint64

  SeatTakeover = object
    ## One human standing in for one policy seat. The human drives the seat's
    ## cog with the SAME eight-button InputState the policy was pressing —
    ## takeover changes WHO is read, nothing else about the sim.
    seat: int        ## config slot index (matches Player.joinOrder). MOVES
                     ## while the takeover is still pending — see
                     ## migratePendingTakeovers.
    requestedSeat: int ## the seat this human originally asked for. Never
                     ## changes, so a surface can find its own row after a
                     ## migration without guessing.
    name: string     ## guest display name, generated app-side.
    active: bool     ## false = "suiting up", pending the next respawn.
    cog: int         ## resolved sim player index, -1 while unresolved.
    observed: bool   ## true once a frame has sampled the cog's alive flag.
    prevAlive: bool  ## that flag on the previously sampled frame.
    cogX, cogY: int  ## where that cog stood on the last sampled frame, in map
                     ## pixels. It is the seat's OWN cog, which the human is
                     ## already looking at, so it hides nothing the fog hides —
                     ## and it is how "is the policy actually driving again?"
                     ## gets a numeric answer instead of a vibe.
    cogAlive: bool   ## the cog's alive flag as of the last sampled frame —
                     ## reported so a surface can say "your cog is down, you
                     ## are in at the next spawn" rather than just "waiting".
    policyMask: uint8 ## the mask the seat's POLICY was pressing on that same
                      ## frame, while it was being ignored. The pair
                      ## (lastMask, policyMask) is the arbitration made
                      ## visible: the policy never stopped playing, its input
                      ## is simply not what the seat applies while a human
                      ## drives — which is why the handback is seamless.
    directAim: bool  ## true when this human's connection asked for, and was
                     ## granted, the direct-aim channel: their turret takes the
                     ## bearing of their cursor in one tick instead of swinging
                     ## at `aimTurnRate`. Granted ONLY on a config that arms
                     ## `allowDirectAim`; a request on a league config is
                     ## refused at the upgrade rather than silently dropped.
    aimBrads: int    ## the bearing this seat's turret was last pointed at
                     ## through that channel, -1 when it is not driving one.
                     ## Echoed on /takeover/status so "am I actually pointing
                     ## where I am pointing?" has an honest answer.
    lastMask: uint8  ## the input mask this seat applied on the last frame,
                     ## echoed back on /takeover/status. It is the human's OWN
                     ## keypress coming back, so it leaks nothing the fog hides
                     ## — and it is the one honest answer to "are my keys
                     ## actually reaching the field?".

  SeatSnapshot = object
    ## One seat's liveness as of the last frame, published for the seat PICKER.
    ## The picker runs on the HTTP thread and the roster lives on the game
    ## thread, so the frame leaves this behind rather than reaching across.
    seat: int          ## config slot index (Player.joinOrder).
    cog: int           ## sim player index.
    alive: bool
    respawnTimer: int  ## ticks until this cog is back on its feet, 0 if up.

  PendingLifecycleRecord = object
    kind: LifecycleRecordKind
    seat: int
    playerIndex: int

  PendingLobbyChat = object
    websocket: WebSocket
    seat: int
    generation: uint64
    packet: LobbyChatSendPacket

  PendingBallotCast = object
    ## MAP VOTE: one 0xA4 send, queued by the socket-side consumer and
    ## admitted (sim.applyBallotCast) on the game thread — the exact
    ## PendingLobbyChat shape, for the exact §9.2 thread-ownership reason.
    websocket: WebSocket
    seat: int
    generation: uint64
    packet: BallotCastPacket

  OutstandingPlayCall = object
    proposalId: uint64
    acceptAcked: bool
    pendingRetunes: seq[ShellEntryIdentity]

  WebSocketAppState = object
    lock: Lock
    replayServerMode: bool
    replayLoaded: bool
    pendingReplayUri: string
    loadingReplayUri: string
    currentReplayUri: string
    resetRequested: bool
    kickRequests: seq[string]
    kickedIdentities: Table[string, bool]
    inputMasks: Table[WebSocket, uint8]
    inputPressedMasks: Table[WebSocket, uint8]
    lastAppliedMasks: Table[WebSocket, uint8]
    chatMessages: Table[WebSocket, string]
    policyPageFlashes: Table[WebSocket, string]
      ## One-page-policy REFLASH inbox, one pending page per seat socket,
      ## drained at the next tick boundary exactly like chatMessages beside
      ## it. A page handed to the sim anywhere but a tick boundary would land
      ## between two hashes and be unrecordable at any single tick, so the
      ## receive side (the websocket handler, which is the policy runner's
      ## half of this feature) never touches the sim — it only drops the page
      ## here.
    playerIndices: Table[WebSocket, int]
    playerAddresses: Table[WebSocket, string]
    playerSlots: Table[WebSocket, int]
    playerTokens: Table[WebSocket, string]
    playerReady: Table[WebSocket, bool]
    ## Sprites Off (0x87) senders: these clients get pixel-free sprite
    ## definitions — id, dimensions, and label with no pixel payload.
    spritesOff: Table[WebSocket, bool]
    globalViewers: Table[WebSocket, GlobalViewerState]
    playerViewers: Table[WebSocket, PlayerViewerState]
    rewardViewers: Table[WebSocket, bool]
    ## Human seat takeovers, keyed by the HUMAN's websocket. A takeover
    ## socket is deliberately NOT a roster player (see
    ## registerTakeoverWebSocket): it never enters `playerIndices`, so it
    ## never joins, never occupies a slot, and never writes a join/leave
    ## record. Empty on every config that leaves allowSeatTakeover off, which
    ## is what makes a league build byte-identical to a pre-takeover build.
    takeovers: Table[WebSocket, SeatTakeover]
    ## Per-seat liveness as of the last frame. Written only on a config that
    ## arms takeover, so it stays an empty seq for a league build's whole run.
    seatBoard: seq[SeatSnapshot]
    closedSockets: seq[WebSocket]
    nextAnonymousPlayer: int
    config: GameConfig
    playProtocolRejected: int
    playSpriteInputIgnored: int
    playSpriteReadyIgnored: int
    playSpriteDebugIgnored: int
    playIngressFeedbackErrors: uint32
    playIngress: seq[PlayIngressSeat[WebSocket]]
    playOutbound: seq[PlayOutboundSeat[WebSocket]]
    outstandingPlayCalls: seq[seq[OutstandingPlayCall]]
    playIngressConfigured: bool
    seatTombstones: seq[SeatTombstone]
    seatPlayerIndices: seq[int]
    shellEpisodeInLobby: bool
    pendingLifecycleRecords: seq[PendingLifecycleRecord]
    pendingPlayCallRecords: seq[PlayCallRecord]
    pendingShellAnnotations: seq[ShellAnnotation]
    pendingLobbyChatRecords: seq[LobbyChatRecord]
    pendingLobbyChats: seq[PendingLobbyChat]
    pendingBallotCasts: seq[PendingBallotCast]
    pendingBallotRecords: seq[BallotRecord]
    voteResolutionRecorded: bool
    lobbyTranscript: seq[LobbyChatRecord]
    lobbyTranscriptTicks: seq[uint32]

  ServerThreadArgs = object
    server: ptr Server
    address: string
    port: int

  PendingPlayerJoin = object
    websocket: WebSocket
    address: string
    token: string
    requestedSlot: int
    slotIndex: int

var
  playReceiveConsumers: PlayReceiveConsumers
  activeShellEpisode {.threadvar.}: ptr ShellEpisode
  activeShellTick {.threadvar.}: uint32

proc saturatingAdd(value: var uint32, amount: int) =
  if amount <= 0:
    return
  let room = uint64(high(uint32) - value)
  value += uint32(min(uint64(amount), room))

proc registerPlayModuleUploadConsumer*(consumer: PlayModuleUploadConsumer) =
  ## Startup-only registration seam consumed by the play-runtime lane.
  playReceiveConsumers.moduleUpload = consumer

proc registerPlayCallConsumer*(consumer: PlayCallConsumer) =
  ## Startup-only registration seam consumed by the play-runtime lane.
  playReceiveConsumers.playCall = consumer

proc registerPlayStatusAckConsumer*(consumer: PlayStatusAckConsumer) =
  ## Startup-only registration seam consumed by the play-runtime lane.
  playReceiveConsumers.statusAck = consumer

proc registerPlayLobbyChatConsumer*(consumer: PlayLobbyChatConsumer) =
  ## Startup-only registration seam consumed by Maxwell's lobby implementation.
  playReceiveConsumers.lobbyChat = consumer

proc registerPlayBallotCastConsumer*(consumer: PlayBallotCastConsumer) =
  ## Startup-only registration seam for the MAP VOTE's 0xA4 ballot casts.
  playReceiveConsumers.ballotCast = consumer

proc registerPlaySeatKickConsumer*(consumer: PlaySeatKickConsumer) =
  ## Lane C drops the ladder/body and returns the safe-hold annotation.
  playReceiveConsumers.kick = consumer

func defuseScriptClose(src: string): string =
  ## Splicing a staticRead'd JS file inline as `<script>` + content +
  ## `</script>` is only safe if the content never contains the literal
  ## bytes "</script" -- HTML's script-raw-text-end scan matches that
  ## sequence case-insensitively no matter where it sits (inside a JS
  ## string, a `/* comment */`, anywhere), and ends the tag right there,
  ## silently truncating the rest of the file and corrupting whatever
  ## HTML gets parsed after it. player_hud.js's own header comment shows
  ## its `<script src="player_hud.js"></script>` include line as example
  ## text, which trips exactly this. Defuse every occurrence (case
  ## insensitive) by splitting the sequence with a backslash -- inert
  ## inside a JS comment or string, but no longer a tag-close to the
  ## HTML parser -- before any inline splice.
  result = newStringOfCap(src.len)
  var i = 0
  while i < src.len:
    if i + 8 <= src.len and src[i] == '<' and src[i + 1] == '/' and
        src[i + 2 ..< i + 8].toLowerAscii() == "script":
      result.add("<\\/script")
      i += 8
    else:
      result.add(src[i])
      inc i

const
  # Sentinel for `appState.playerIndices`: a player websocket that has
  # registered but has not yet been resolved into a live `sim.players`
  # slot (join admission is strictly slot-sequential and can take more
  # than one tick). It is deliberately far outside any real array index so
  # the "still pending" scan (`== UnresolvedPlayerIndex`) never collides
  # with a resolved one. It must NEVER be treated as a real index by
  # arithmetic that shifts indices after a removal (see `removePlayer`) --
  # doing so corrupts it into a value that can never match the pending
  # scan again, permanently orphaning that socket even though it is still
  # connected.
  UnresolvedPlayerIndex = 0x7fffffff
  HealthPath = "/healthz"
  AdminWebSocketPath = "/admin"
  # Freeplay seat takeover. A dedicated websocket route rather than a flag on
  # /player: the stock player client force-copies name/token/slot onto
  # whatever `address` it is given, so a browser reaches this path with no
  # client change at all, and the roster's player path stays untouched.
  TakeoverWebSocketPath = "/takeover"
  TakeoverStatusPath = "/takeover/status"
  # "Which seat should this arrival take?" -- answered by the server because
  # only the server knows which cog is lying down right now.
  TakeoverSeatPath = "/takeover/seat"
  TakeoverClientPath = "/client/takeover"
  # global_plus_pov: the god's-eye board with a selectable seat's POV
  # composited as a corner inset (viability PRD's fourth render view). Two
  # routes for parity with the existing global_observer/agent_pov pages,
  # which are ALSO reachable both live and against a loaded replay: the live
  # spectator route and the hosted-replay route. Both serve the identical
  # embedded HTML (see EmbeddedGlobalPlusPovHtml below) -- the page itself
  # self-detects live vs. replay off its own URL, exactly like
  # EmbeddedBroadcastReplayHtml already does for /client/global vs.
  # /client/replay.
  GlobalPlusPovClientPath = "/client/global_plus_pov"
  ReplayPlusPovClientPath = "/client/replay_plus_pov"
  # What a human connection may be GRANTED here. Polled by the client before
  # it connects, so one bundle serves both a league server and a play server.
  CapabilitiesPath = "/capabilities"
  ControlRestartPath = "/control/restart"
  ControlKickPath = "/control/kick"
  ## Cap on player debug-sprite bytes accepted per player per tick.
  MaxDebugSpriteBytesPerTick* = 32 * 1024
  # The designed broadcast replay client, embedded at compile time. Served for
  # the replay routes in place of bitworld's generic global client; a single
  # self-contained file (shared chrome + core JS inlined). Live/player/global
  # paths are untouched and keep serving the bitworld client (§14 live column).
  # Final in-page script order: wire constants, shared chrome, core, page IIFE
  # (marker positions in the HTML fix that; the replace order here is free).
  EmbeddedBroadcastReplayHtml = staticRead("../../client/replay_broadcast.html").replace(
    "<!-- CHROME_COMMON -->",
    "<script>" & staticRead("../../client/chrome_common.js") & "</script>"
  ).replace(
    "<!-- BROADCAST_CORE -->",
    "<script>" & staticRead("../../client/broadcast_core.js") & "</script>"
  ).spliceWireConstants()
  # global_plus_pov: forked from the broadcast replay client above (same
  # splice contract) rather than sharing its markup/script -- the fork adds
  # a second BroadcastCore connection (the POV inset) and redirects the `v:`
  # command to drive it instead of swapping this page's own board away. See
  # the long comment at the top of client/global_plus_pov.html's script for
  # the full design; server-side this is pure additive routing, nothing here
  # touches sim state or gameHash.
  EmbeddedGlobalPlusPovHtml = staticRead("../../client/global_plus_pov.html").replace(
    "<!-- CHROME_COMMON -->",
    "<script>" & staticRead("../../client/chrome_common.js") & "</script>"
  ).replace(
    "<!-- BROADCAST_CORE -->",
    "<script>" & staticRead("../../client/broadcast_core.js") & "</script>"
  ).spliceWireConstants()
  # The League Replayer shell: a walled stone-pit viewer that EMBEDS the broadcast
  # client (via ?embed=1) as the lit pit floor and mounts the scorebug, KDA tables,
  # division standings and transport as flat panels over the dungeon walls. Served
  # at the bare replay route; embed=1 falls through to the plain broadcast client.
  # Shares the same chrome_common.js splice as the broadcast client.
  EmbeddedLeagueReplayerHtml = staticRead("../../client/league_replayer.html").replace(
    "<!-- CHROME_COMMON -->",
    "<script>" & staticRead("../../client/chrome_common.js") & "</script>"
  ).spliceWireConstants()
  # SEASON 2 HUMAN SEAT, ported from maxwell/s2-controls-on-seat (byte-matched
  # source, GameVersion 44 origin; this tree sits on main's GV47 after the
  # wave-1 reconciliation — the 8-bit InputState mask and the /player
  # websocket handshake are untouched by any of it, per sim_types.nim's
  # GameVersion changelog comment). Our OWN player
  # client, vendored into this repo rather than patched into the pinned
  # ~/.nimby/pkgs/bitworld package -- the same ELEVATE-BY-REBUILD move the
  # replay routes above already make. player_controls.js carries the
  # keyboard/mouse -> action-space translation and is inlined so the page
  # stays a single self-contained file. player_hud.js (maxwell/player-hud) gets
  # the same treatment: the inlined <script> block IS what /client/player
  # serves, at compile time (staticRead reads this file's CURRENT bytes into
  # the binary), so the page never depends on a separate runtime fetch for
  # either file, and any branch that edits client/player_hud.js and merges
  # its changes here picks them up automatically on the next build -- no
  # extra wiring needed. Do NOT also add a real <script src="player_hud.js">
  # tag or a server route that serves this file's CONTENT at that URL: the
  # HUD is already loaded via the inline block above, so either one would
  # execute the whole script a second time. `/client/player_hud.js` as a
  # bare URL is intentionally never given real content; the unmatched-path
  # fallback below (see the /client/* 404 branch) is what keeps a stray
  # direct request to it from lying with a 200 instead of failing loud.
  # DO NOT move this HTML to a different serving route or base path. Its
  # OTHER bare <script src=...> tag (snappyjs.min.js) resolves relative to
  # wherever this page is served from -- currently /client/player, which
  # happens to line up with bitworld's OWN generic client router serving
  # /client/snappyjs.min.js (a completely separate staticRead'd asset, from
  # the vendored bitworld package, not this repo's client/ dir). That
  # alignment is accidental, not designed, and there is no static route
  # here to fall back on if it breaks: a human client would silently lose
  # snappy sprite decode, desync mid-packet, and have its websocket closed
  # -- bots keep playing, humans go dark. Changing this route is a decision
  # for whoever owns that risk, not a drive-by tidy-up.
  EmbeddedPlayerClientHtml = staticRead("../../client/player_client.html").replace(
    "<script src=\"player_controls.js\"></script>",
    "<script>" & defuseScriptClose(staticRead("../../client/player_controls.js")) &
      "</script>"
  ).replace(
    "<script src=\"player_hud.js\"></script>",
    "<script>" & defuseScriptClose(staticRead("../../client/player_hud.js")) &
      "</script>"
  )
  # Dungeon-wall textures (nanobanana generations) served as static assets so the
  # shell HTML stays small and editable. Wide for top/bottom, tall for side walls.
  # Opaque stone, no alpha → JPEG (q82) keeps each well under any committed sprite.
  # The freeplay takeover shell: the stock player client in a frame plus the
  # seat's takeover state ("suiting up" -> "you're driving"), polled off
  # /takeover/status. Served only when allowSeatTakeover is on.
  EmbeddedTakeoverHtml = staticRead("../../client/takeover.html")
  WallTextureHorizontal = staticRead("../../client/art/walls/wall_h.jpg")
  WallTextureVertical = staticRead("../../client/art/walls/wall_v.jpg")
  # The broadcast client's pre-load curtain scene (nanobanana generations,
  # like the walls): the bot locker room as ONE empty-room plate (bg.jpg)
  # plus five alpha-sprite poses per cog (<bot>_<pose>.webp) that the
  # client layers and cycles on top. One entry per asset, served by path
  # lookup like the soldier art; content type derives from the suffix.
  LockerRoomAssets = [
    ("/client/art/lockerroom/bg.jpg",
      staticRead("../../client/art/lockerroom/bg.jpg")),
    ("/client/art/lockerroom/green_1.webp",
      staticRead("../../client/art/lockerroom/green_1.webp")),
    ("/client/art/lockerroom/green_2.webp",
      staticRead("../../client/art/lockerroom/green_2.webp")),
    ("/client/art/lockerroom/green_3.webp",
      staticRead("../../client/art/lockerroom/green_3.webp")),
    ("/client/art/lockerroom/green_5.webp",
      staticRead("../../client/art/lockerroom/green_5.webp")),
    ("/client/art/lockerroom/green_6.webp",
      staticRead("../../client/art/lockerroom/green_6.webp")),
    ("/client/art/lockerroom/blue_1.webp",
      staticRead("../../client/art/lockerroom/blue_1.webp")),
    ("/client/art/lockerroom/blue_2.webp",
      staticRead("../../client/art/lockerroom/blue_2.webp")),
    ("/client/art/lockerroom/blue_3.webp",
      staticRead("../../client/art/lockerroom/blue_3.webp")),
    ("/client/art/lockerroom/blue_5.webp",
      staticRead("../../client/art/lockerroom/blue_5.webp")),
    ("/client/art/lockerroom/blue_6.webp",
      staticRead("../../client/art/lockerroom/blue_6.webp")),
    ("/client/art/lockerroom/yellow_1.webp",
      staticRead("../../client/art/lockerroom/yellow_1.webp")),
    ("/client/art/lockerroom/yellow_2.webp",
      staticRead("../../client/art/lockerroom/yellow_2.webp")),
    ("/client/art/lockerroom/yellow_3.webp",
      staticRead("../../client/art/lockerroom/yellow_3.webp")),
    ("/client/art/lockerroom/yellow_5.webp",
      staticRead("../../client/art/lockerroom/yellow_5.webp")),
    ("/client/art/lockerroom/yellow_6.webp",
      staticRead("../../client/art/lockerroom/yellow_6.webp")),
    ("/client/art/lockerroom/red_1.webp",
      staticRead("../../client/art/lockerroom/red_1.webp")),
    ("/client/art/lockerroom/red_2.webp",
      staticRead("../../client/art/lockerroom/red_2.webp")),
    ("/client/art/lockerroom/red_3.webp",
      staticRead("../../client/art/lockerroom/red_3.webp")),
    ("/client/art/lockerroom/red_5.webp",
      staticRead("../../client/art/lockerroom/red_5.webp")),
    ("/client/art/lockerroom/red_6.webp",
      staticRead("../../client/art/lockerroom/red_6.webp")),
  ]
  BroadcastFont = staticRead("../../data/font.ttf")
  # Cog art for the first-person EYES PiP billboards (real body + legs + wheels
  # + cyan visor, team-tinted). Served as static PNGs so the raycast view can
  # blit the true cog instead of a procedural chassis.
  #
  # The _front masters are drawn from a HORIZONTAL, eye-level camera with the
  # smile visor tilted up toward the viewer (scripts/art/build_cvc_front.py) —
  # that is what the PiP blits. The plain soldier_{red,blue} masters are the
  # TOP-DOWN board sprites (the cog seen from ABOVE): they stay served as the
  # PiP's fallback, but an overhead projection in an eye-level view reads as a
  # flat plate with the face squashed onto its lower lip, so the front masters
  # are what the billboard actually wants.
  # ...and the same cogs holding their paintball marker forward at the camera.
  # A live cog always carries its gun, so this is the pose the PiP shows for any
  # armed cog; the empty-handed masters cover the unarmed read. One entry per
  # team x {top-down, front, front_gun}, served by path lookup.
  TeamNames: array[Team, string] = block:
    ## teamText as a compile-time table, so paths below can be staticRead.
    var n: array[Team, string]
    for team in Team:
      n[team] = teamText(team)
    n
  SoldierArtAssets = block:
    ## BR INTEGRATION: derived from the enum, not a hand-listed four. This
    ## list used to name Red/Blue/Green/Yellow literally, which meant the 12
    ## BR identities' front masters — present on disk since the tint lane —
    ## were never SERVED, so a plum or azure cog fell back to the top-down
    ## board sprite in the first-person PiP while its teammates in classic
    ## colours got the real eye-level art. That is exactly the "literal
    ## 4-multiplier" hazard BR_MAPGEN.md §6.2 calls out, in asset form.
    ##
    ## staticRead resolves at COMPILE time, so this block is also the
    ## strongest possible assertion that all 2 x 16 front masters exist: a
    ## missing one is a build failure, not a runtime fallback.
    var assets: seq[(string, string)]
    for team in Team:
      assets.add(
        ("/client/soldier_" & TeamNames[team] & "_front.png",
          staticRead("../../data/soldier_" & TeamNames[team] & "_front.png")))
      assets.add(
        ("/client/soldier_" & TeamNames[team] & "_front_gun.png",
          staticRead(
            "../../data/soldier_" & TeamNames[team] & "_front_gun.png")))
    assets
  LeagueReplayerPath = "/client/league"
  WallTextureHorizontalPath = "/client/art/walls/wall_h.jpg"
  WallTextureVerticalPath = "/client/art/walls/wall_v.jpg"
  BroadcastFontPath = "/client/font.ttf"
  # Hosted replay closes any WS frame larger than 1 MiB (sends 1009). We chunk
  # outbound sprite packets under a margin below that so no single frame trips it.
  MaxWsFrameBytes* = 900_000
  ShutdownGraceSeconds = 20  ## paintball squad mode: /healthz + /global keep
                             ## answering this long after the artifacts are
                             ## written, then the process exits.
  # SpriteClientReady (0x85) and SpriteClientDebugSprite (0x86) now come from
  # bitworld/spriteprotocol: the pin carries both, and still keeps ButtonC,
  # which the grenade input bit needs.

proc liveProgressMaxTick(config: GameConfig): int =
  ## Returns the live viewer tick-bar budget.
  if config.maxTicks > 0:
    config.maxTicks
  else:
    MaxTicks

proc liveSpeedIndex(config: GameConfig): int =
  ## Returns the live playback speed index for a config.
  for i, speed in PlaybackSpeeds:
    if speed == config.speed:
      return i
  0

proc isWebSocketUpgrade(request: Request): bool =
  ## Returns true when the GET request is a websocket upgrade.
  request.headers["Sec-WebSocket-Key"].len > 0

proc replayFilePath(uri: string): string =
  ## Resolves one local replay URI to a host path.
  const FilePrefix = "file://"
  if uri.startsWith(FilePrefix):
    return uri[FilePrefix.len .. ^1]
  if "://" in uri:
    return ""
  uri

let replayDownloadPool = newCurlPool(1)

proc loadReplayUri(uri: string): CtfReplayData =
  ## Loads a replay from a local file URI or HTTP(S) URL.
  ctfReplayCodec.parseCtfReplayBytes(
    readCogameUri(uri, CogameLoadReplayUriEnv),
    CtfReplaySpec,
    ReplayCompatibleGameVersions)

proc readableReplayUri(uri: string): bool =
  ## Returns true when a replay URI can be opened by this server.
  if uri.len == 0:
    return false
  if uri.startsWith("http://") or uri.startsWith("https://"):
    return replayDownloadPool.head(uri).code == 200
  let path = replayFilePath(uri)
  path.len > 0 and fileExists(path)

proc rewardAddress(address: string): string =
  ## Formats one reward address as host:port.
  let parts = address.splitWhitespace()
  if parts.len >= 2:
    return parts[0] & ":" & parts[1]
  address

var appState: WebSocketAppState

proc markSocketClosed(websocket: WebSocket): bool =
  ## Queues a websocket for closed-socket cleanup and returns true once.
  result = websocket notin appState.closedSockets
  if result:
    appState.closedSockets.add(websocket)

proc initAppState() =
  initLock(appState.lock)
  appState.replayServerMode = false
  appState.replayLoaded = false
  appState.pendingReplayUri = ""
  appState.loadingReplayUri = ""
  appState.currentReplayUri = ""
  appState.resetRequested = false
  appState.kickRequests = @[]
  appState.kickedIdentities = initTable[string, bool]()
  appState.inputMasks = initTable[WebSocket, uint8]()
  appState.inputPressedMasks = initTable[WebSocket, uint8]()
  appState.lastAppliedMasks = initTable[WebSocket, uint8]()
  appState.chatMessages = initTable[WebSocket, string]()
  appState.policyPageFlashes = initTable[WebSocket, string]()
  appState.playerIndices = initTable[WebSocket, int]()
  appState.playerAddresses = initTable[WebSocket, string]()
  appState.playerSlots = initTable[WebSocket, int]()
  appState.playerTokens = initTable[WebSocket, string]()
  appState.playerReady = initTable[WebSocket, bool]()
  appState.globalViewers = initTable[WebSocket, GlobalViewerState]()
  appState.playerViewers = initTable[WebSocket, PlayerViewerState]()
  appState.rewardViewers = initTable[WebSocket, bool]()
  appState.takeovers = initTable[WebSocket, SeatTakeover]()
  appState.seatBoard = @[]
  appState.closedSockets = @[]
  appState.nextAnonymousPlayer = 1
  appState.config = defaultGameConfig()
  appState.playProtocolRejected = 0
  appState.playSpriteInputIgnored = 0
  appState.playSpriteReadyIgnored = 0
  appState.playSpriteDebugIgnored = 0
  appState.playIngressFeedbackErrors = 0
  appState.playIngress = @[]
  appState.playOutbound = @[]
  appState.outstandingPlayCalls = @[]
  appState.playIngressConfigured = false
  appState.seatTombstones = @[]
  appState.seatPlayerIndices = @[]
  appState.shellEpisodeInLobby = true
  appState.pendingLifecycleRecords = @[]
  appState.pendingPlayCallRecords = @[]
  appState.pendingShellAnnotations = @[]
  appState.pendingLobbyChatRecords = @[]
  appState.pendingLobbyChats = @[]
  appState.lobbyTranscript = @[]
  appState.lobbyTranscriptTicks = @[]

proc comparePendingPlayerJoins(
  a,
  b: PendingPlayerJoin
): int =
  ## Orders pending players by resolved slot and identity.
  result = cmp(a.slotIndex, b.slotIndex)
  if result != 0:
    return
  result = cmp(a.address, b.address)

proc pendingPlayerJoin(
  sim: SimServer,
  websocket: WebSocket
): PendingPlayerJoin =
  ## Resolves one pending websocket into a join candidate.
  result.websocket = websocket
  result.address = appState.playerAddresses.getOrDefault(websocket, "unknown")
  result.requestedSlot = appState.playerSlots.getOrDefault(websocket, -1)
  result.token = appState.playerTokens.getOrDefault(websocket, "")
  result.slotIndex = sim.resolvePlayerSlot(
    result.address,
    result.token,
    result.requestedSlot
  )

proc removePlayerWebSocketState(websocket: WebSocket): int =
  ## Removes player-owned websocket state and returns its former index.
  result = -1
  if websocket in appState.playerViewers:
    appState.playerViewers.del(websocket)
  if websocket in appState.playerIndices:
    result = appState.playerIndices[websocket]
    appState.playerIndices.del(websocket)
  appState.inputMasks.del(websocket)
  appState.inputPressedMasks.del(websocket)
  appState.lastAppliedMasks.del(websocket)
  appState.chatMessages.del(websocket)
  appState.policyPageFlashes.del(websocket)
  appState.playerAddresses.del(websocket)
  appState.playerSlots.del(websocket)
  appState.playerTokens.del(websocket)
  appState.playerReady.del(websocket)
  appState.spritesOff.del(websocket)
  # Dropping the takeover entry IS the reverse handoff: the next frame finds
  # no driver for that cog and reads the policy socket's mask again.
  appState.takeovers.del(websocket)

proc isPlayerReadyPacket*(message: string): bool =
  ## Returns true for the one-byte Sprite v1 player-ready packet.
  message.len == 1 and message[0].uint8 == SpriteClientReady

proc isSpritesOffPacket*(message: string): bool =
  ## Returns true for the one-byte Sprite v1 sprites-off packet (0x87).
  ## The pinned bitworld predates the packet, so the id is declared here
  ## rather than imported.
  message.len == 1 and message[0].uint8 == 0x87'u8

proc addressIsKicked(address: string): bool =
  ## Returns true when an address is blocked from this match.
  let identity = address.rewardAddress()
  address in appState.kickedIdentities or identity in appState.kickedIdentities

proc configurePlayIngress(config: GameConfig) =
  appState.playIngress = newSeq[PlayIngressSeat[WebSocket]](config.slots.len)
  appState.playOutbound = newSeq[PlayOutboundSeat[WebSocket]](config.slots.len)
  appState.outstandingPlayCalls =
    newSeq[seq[OutstandingPlayCall]](config.slots.len)
  appState.seatTombstones = newSeq[SeatTombstone](config.slots.len)
  appState.seatPlayerIndices = newSeq[int](config.slots.len)
  for seat in 0 ..< appState.playIngress.len:
    appState.playIngress[seat] = initPlayIngressSeat[WebSocket]()
    appState.seatTombstones[seat] = initSeatTombstone()
    appState.seatPlayerIndices[seat] = -1
  appState.pendingLifecycleRecords = @[]
  appState.pendingPlayCallRecords = @[]
  appState.pendingShellAnnotations = @[]
  appState.pendingLobbyChatRecords = @[]
  appState.pendingLobbyChats = @[]
  appState.lobbyTranscript = @[]
  appState.lobbyTranscriptTicks = @[]
  appState.playIngressConfigured = true

proc ensurePlayIngressConfigured() =
  if not appState.playIngressConfigured:
    configurePlayIngress(appState.config)

proc playIngressSeat(seat: int): ptr PlayIngressSeat[WebSocket] =
  ensurePlayIngressConfigured()
  if seat >= 0 and seat < appState.playIngress.len and
      appState.config.isPlaySeat(seat):
    return appState.playIngress[seat].addr
  nil

proc retainWireRefusal(seat: int; generation: uint64; opcode: uint8;
                       id: uint64; reason: string) =
  ## Caller holds appState.lock. The frozen status union has no generic
  ## protocol-error arm, so malformed non-upload packets use call_rejected
  ## with proposal_id 0 and an opcode-qualified reason.
  if seat < 0 or seat >= appState.playOutbound.len:
    return
  if opcode == OpModuleUpload:
    discard appState.playOutbound[seat].retainModuleRefusal(
      generation, id, reason)
  else:
    discard appState.playOutbound[seat].retainCallRefusal(
      generation, id, "opcode_0x" & opcode.toHex(2).toLowerAscii & ":" & reason)

proc packetIdIfPresent(data: string): uint64 =
  ## Packet ids are read as unsigned values before any conversion. Both A0
  ## and A1 place their u64 id at byte 2; malformed shorter packets use zero.
  if data.len < 10:
    return 0
  for index in 0 ..< 8:
    result = result or (uint64(uint8(data[2 + index])) shl (index * 8))

proc applyPlayIngressFeedback*(seat: int; feedback: PlayIngressFeedback)
proc queueAcceptedPlayCallIdentity(expectedSeat: int;
    identity: Option[ShellCallReplayIdentity];
    replayTimeMs: uint32): bool {.gcsafe.}

proc packetModuleBytes(packet: ModuleUploadPacket): seq[byte] =
  result = newSeq[byte](packet.wasm.len)
  if packet.wasm.len > 0:
    copyMem(addr result[0], unsafeAddr packet.wasm[0], packet.wasm.len)

proc handleProductionModuleUpload(
  websocket: WebSocket,
  seat: int,
  generation: uint64,
  packet: ModuleUploadPacket,
) {.gcsafe.} =
  ## Runs synchronously on the game thread while the tick drain scopes the
  ## live episode. Compilation itself remains non-blocking in lane A's plane.
  discard websocket
  let episode = activeShellEpisode
  var admitted: ShellAdmissionResult
  if episode == nil:
    admitted.reason = "runtimeUnavailable"
  else:
    let moduleBytes = packet.packetModuleBytes()
    {.cast(gcsafe).}:
      admitted = episode[].admitPlayModule(
        seat, packet.uploadId, generation, moduleBytes)
  var releaseUnusedAdmissionSlot = false
  {.gcsafe.}:
    withLock appState.lock:
      if seat < 0 or seat >= appState.playOutbound.len:
        return
      if admitted.accepted:
        discard appState.playOutbound[seat].retainStatus(
          admitted.status, reservationSlots = 1)
      else:
        discard appState.playOutbound[seat].retainModuleRefusal(
          generation, packet.uploadId, admitted.reason,
          spontaneous = false, reservationSlots = 1)
        releaseUnusedAdmissionSlot = true
  if releaseUnusedAdmissionSlot:
    {.cast(gcsafe).}:
      applyPlayIngressFeedback(seat, PlayIngressFeedback(
        statusSlotsRetired: 1))

proc handleProductionPlayCall(
  websocket: WebSocket,
  seat: int,
  generation: uint64,
  packet: PlayCallPacket,
) {.gcsafe.} =
  ## The episode resolves bindings and owns the ladder. This adapter retains
  ## its verdict, releases unused reservations, and queues only the surfaced
  ## accepted-call replay identity.
  discard websocket
  let episode = activeShellEpisode
  var accepted: ShellCallResult
  if episode == nil:
    accepted.reason = "runtimeUnavailable"
    accepted.path = "runtime"
  else:
    {.cast(gcsafe).}:
      accepted = episode[].acceptPlayCall(
        seat, packet.proposalId, generation, activeShellTick,
        packet.callBytes)
  {.gcsafe.}:
    withLock appState.lock:
      if seat < 0 or seat >= appState.playOutbound.len:
        return
      if accepted.status.kind in {skCallAccepted, skCallRejected}:
        discard appState.playOutbound[seat].retainStatus(
          accepted.status, reservationSlots = 1,
          proposalId = some(packet.proposalId))
      else:
        discard appState.playOutbound[seat].retainCallRefusal(
          generation, packet.proposalId,
          accepted.reason & ":" & accepted.path,
          spontaneous = false, reservationSlots = 1)
  if not accepted.accepted:
    # A rejected call schedules no retunes. Its one delivered status remains
    # reserved until StatusAck, which also evicts the proposal payload.
    {.cast(gcsafe).}:
      applyPlayIngressFeedback(seat, PlayIngressFeedback(
        statusSlotsRetired: MaxLadderEntries))
  else:
    {.gcsafe.}:
      withLock appState.lock:
        if seat < 0 or seat >= appState.outstandingPlayCalls.len:
          appState.playIngressFeedbackErrors.saturatingAdd(1)
          return
        appState.outstandingPlayCalls[seat].add(OutstandingPlayCall(
          proposalId: packet.proposalId,
          pendingRetunes: accepted.pendingRetunes))
    {.cast(gcsafe).}:
      applyPlayIngressFeedback(seat, PlayIngressFeedback(
        statusSlotsRetired:
          MaxLadderEntries - accepted.pendingRetunes.len))
    # Production drains calls for sim.tickCount + 1 before stepping that tick.
    # Subtracting one therefore stamps the same tickTime(sim.tickCount) used
    # by the replay batch and lobby-chat records from this drain.
    let replayTick =
      if activeShellTick > 0: activeShellTick - 1 else: 0'u32
    discard queueAcceptedPlayCallIdentity(
      seat, accepted.replayIdentity, tickTime(replayTick.int))

proc retainProductionModuleStatuses(
    statuses: openArray[ShellModuleStatus]) =
  ## Async compile terminals consume the second slot reserved at upload
  ## admission. Client acknowledgment later retires that delivered slot.
  {.gcsafe.}:
    withLock appState.lock:
      for terminal in statuses:
        if terminal.seat < 0 or terminal.seat >= appState.playOutbound.len:
          appState.playIngressFeedbackErrors.saturatingAdd(1)
          continue
        discard appState.playOutbound[terminal.seat].retainStatus(
          terminal.status, reservationSlots = 1)

proc countPlayOutcomeFeedbackError(seat: int) =
  appState.playIngressFeedbackErrors.saturatingAdd(1)
  if seat >= 0 and seat < appState.playIngress.len:
    appState.playIngress[seat].notePlayIngressFeedbackError()

proc findOutstandingRetune(seat: int; entryId: string;
                           play = ""): tuple[callIndex, entryIndex: int] =
  result = (-1, -1)
  if seat < 0 or seat >= appState.outstandingPlayCalls.len:
    return
  for callIndex, call in appState.outstandingPlayCalls[seat]:
    for entryIndex, identity in call.pendingRetunes:
      if identity.entryId == entryId and
          (play.len == 0 or identity.play == play):
        return (callIndex, entryIndex)

proc completeOutstandingRetune(seat, callIndex, entryIndex: int;
    feedback: var PlayIngressFeedback) =
  var call = addr appState.outstandingPlayCalls[seat][callIndex]
  call[].pendingRetunes.delete(entryIndex)
  if call[].pendingRetunes.len == 0 and call[].acceptAcked:
    feedback.retiredProposalIds.add(call[].proposalId)
    appState.outstandingPlayCalls[seat].delete(callIndex)

proc retainProductionLadderOutcomes(
    ladderStatuses: openArray[ShellLadderStatus];
    retuned: openArray[ShellEntryIdentity]) =
  ## Converts lane C's exactly-once completion channel into reservation
  ## retirement. Calls are kept in admission order, so repeated entry
  ## identities across successive proposals retire the oldest outstanding
  ## occurrence first.
  var feedback = newSeq[PlayIngressFeedback](appState.playIngress.len)
  {.gcsafe.}:
    withLock appState.lock:
      for identity in retuned:
        if identity.seat < 0 or identity.seat >= appState.playIngress.len:
          countPlayOutcomeFeedbackError(identity.seat)
          continue
        let found = findOutstandingRetune(
          identity.seat, identity.entryId, identity.play)
        if found.callIndex < 0:
          countPlayOutcomeFeedbackError(identity.seat)
          continue
        feedback[identity.seat].statusSlotsRetired += 1
        completeOutstandingRetune(
          identity.seat, found.callIndex, found.entryIndex,
          feedback[identity.seat])

      for row in ladderStatuses:
        if row.seat < 0 or row.seat >= appState.playIngress.len:
          countPlayOutcomeFeedbackError(row.seat)
          continue
        let found = findOutstandingRetune(row.seat, row.entryId)
        if found.callIndex >= 0:
          # The durable list owns the wire ordinal. The standard path stamps
          # that one field, fits the landed value, and encodes it; lane C's
          # pre-encoded ladder-local statusBytes are intentionally not a wire
          # input here.
          discard appState.playOutbound[row.seat].retainStatus(
            row.status, reservationSlots = 1)
          completeOutstandingRetune(
            row.seat, found.callIndex, found.entryIndex, feedback[row.seat])
        elif row.status.kind == skPlayFaulted:
          discard appState.playOutbound[row.seat].retainStatus(
            row.status, reservationSlots = 0, spontaneous = true)
        else:
          countPlayOutcomeFeedbackError(row.seat)

  for seat, outcome in feedback:
    if outcome.statusSlotsRetired > 0 or outcome.retiredProposalIds.len > 0:
      applyPlayIngressFeedback(seat, outcome)

proc handleProductionStatusAck(
  websocket: WebSocket,
  seat: int,
  packet: StatusAckPacket,
): PlayIngressFeedback {.gcsafe.} =
  discard websocket
  {.gcsafe.}:
    withLock appState.lock:
      if seat < 0 or seat >= appState.playOutbound.len:
        return
      let retired = appState.playOutbound[seat].acknowledge(packet.mark)
      if not retired.valid:
        let generation = appState.playOutbound[seat].generation
        discard appState.playOutbound[seat].retainCallRefusal(
          generation, 0, "status_ack_out_of_range")
        return
      result.statusSlotsRetired = retired.statusSlotsRetired
      for proposalId in retired.retiredProposalIds:
        var callIndex = -1
        for index, call in appState.outstandingPlayCalls[seat]:
          if call.proposalId == proposalId:
            callIndex = index
            break
        if callIndex < 0:
          # Rejected calls never create outstanding completion state.
          result.retiredProposalIds.add(proposalId)
        elif appState.outstandingPlayCalls[seat][callIndex].pendingRetunes.len == 0:
          result.retiredProposalIds.add(proposalId)
          appState.outstandingPlayCalls[seat].delete(callIndex)
        else:
          appState.outstandingPlayCalls[seat][callIndex].acceptAcked = true

proc handleProductionLobbyChat(
  websocket: WebSocket,
  seat: int,
  packet: LobbyChatSendPacket,
) {.gcsafe.} =
  ## Called by dispatch while appState.lock is held. The sim-side five-step
  ## text admission remains game-thread-owned and runs from this bounded inbox.
  {.cast(gcsafe).}:
    if seat < 0 or seat >= appState.playIngress.len:
      return
    appState.pendingLobbyChats.add(PendingLobbyChat(
      websocket: websocket, seat: seat,
      generation: appState.playIngress[seat].binding.generation,
      packet: packet))

proc handleProductionBallotCast(
  websocket: WebSocket,
  seat: int,
  packet: BallotCastPacket,
) {.gcsafe.} =
  ## Called by dispatch while appState.lock is held — PendingLobbyChat's
  ## exact shape. Admission (window/dedup/rate/spacing, sim.applyBallotCast)
  ## stays game-thread-owned and runs from this bounded inbox.
  {.cast(gcsafe).}:
    if seat < 0 or seat >= appState.playIngress.len:
      return
    appState.pendingBallotCasts.add(PendingBallotCast(
      websocket: websocket, seat: seat,
      generation: appState.playIngress[seat].binding.generation,
      packet: packet))

proc installProductionPlayConsumers(config: GameConfig) =
  ## The five registrations are live only for the conjunctive play-seat gate.
  if config.isPlaySeatEpisode():
    registerPlayModuleUploadConsumer(
      handleProductionModuleUpload)
    registerPlayCallConsumer(handleProductionPlayCall)
    registerPlayStatusAckConsumer(handleProductionStatusAck)
    registerPlayLobbyChatConsumer(handleProductionLobbyChat)
    registerPlayBallotCastConsumer(handleProductionBallotCast)
  else:
    registerPlayModuleUploadConsumer(nil)
    registerPlayCallConsumer(nil)
    registerPlayStatusAckConsumer(nil)
    registerPlayLobbyChatConsumer(nil)
    registerPlayBallotCastConsumer(nil)

proc registerPlayerWebSocket(
  websocket: WebSocket,
  identity: string,
  slot: int,
  token: string,
  replacedPlaySocket: var bool,
  oldPlaySocket: var WebSocket,
): bool =
  ## Registers one websocket as a player connection.
  appState.globalViewers.del(websocket)
  appState.rewardViewers.del(websocket)
  discard removePlayerWebSocketState(websocket)
  if identity.addressIsKicked():
    return false
  var restoredPlayerIndex =
    if appState.replayLoaded: -1 else: UnresolvedPlayerIndex
  if appState.config.isPlaySeatEpisode() and
      slot >= 0 and slot < appState.seatTombstones.len:
    if appState.seatTombstones[slot].presence == spTerminal:
      return false
    if appState.config.slots[slot].control == scInput and
        appState.seatTombstones[slot].presence == spReconnectable:
      if not appState.shellEpisodeInLobby or
          not appState.seatTombstones[slot].rebind(inLobby = true):
        return false
      restoredPlayerIndex = appState.seatPlayerIndices[slot]
      appState.pendingLifecycleRecords.add(PendingLifecycleRecord(
        kind: lrRebind, seat: slot, playerIndex: restoredPlayerIndex))
  let ingressSeat = slot.playIngressSeat()
  if ingressSeat != nil:
    let bound = ingressSeat[].binding.bindSocket(websocket)
    let transcriptMark =
      if appState.lobbyTranscript.len == 0: 0'u64
      else: appState.lobbyTranscript[^1].ordinal
    appState.playOutbound[slot].bindOutbound(
      websocket, bound.generation, transcriptMark)
    # The generation bump precedes stale eviction. The old payloads cannot
    # cross the seam, while every per-tick counter remains charged until the
    # actual tick drain resets it.
    discard ingressSeat[].takeStatusAck()
    ingressSeat[].evictStalePending()
    if bound.replaced:
      replacedPlaySocket = true
      oldPlaySocket = bound.oldSocket
      restoredPlayerIndex = appState.playerIndices.getOrDefault(
        oldPlaySocket, ingressSeat[].playerIndex)
      if restoredPlayerIndex >= 0 and restoredPlayerIndex < UnresolvedPlayerIndex:
        ingressSeat[].playerIndex = restoredPlayerIndex
      discard removePlayerWebSocketState(oldPlaySocket)
    elif ingressSeat[].playerIndex >= 0:
      restoredPlayerIndex = ingressSeat[].playerIndex
  elif appState.config.isPlaySeatEpisode() and
      slot >= 0 and slot < appState.seatPlayerIndices.len and
      appState.seatPlayerIndices[slot] >= 0:
    restoredPlayerIndex = appState.seatPlayerIndices[slot]
  appState.playerViewers[websocket] = initPlayerViewerState()
  appState.playerAddresses[websocket] = identity
  appState.playerSlots[websocket] = slot
  appState.playerTokens[websocket] = token
  appState.playerIndices[websocket] = restoredPlayerIndex
  appState.inputMasks[websocket] = 0
  appState.inputPressedMasks[websocket] = 0
  appState.lastAppliedMasks[websocket] = 0
  appState.playerReady[websocket] = false
  true

proc registerPlayerWebSocket(
  websocket: WebSocket,
  identity: string,
  slot: int,
  token: string,
): bool =
  var
    replacedPlaySocket = false
    oldPlaySocket: WebSocket
  websocket.registerPlayerWebSocket(
    identity, slot, token, replacedPlaySocket, oldPlaySocket)

proc takeoverSeatTaken(seat: int): bool =
  ## Returns true when a human already holds (or is suiting up for) a seat.
  for _, takeover in appState.takeovers.pairs:
    if takeover.seat == seat:
      return true
  false

proc registerTakeoverWebSocket(
  websocket: WebSocket,
  seat: int,
  name: string,
  directAim: bool
) =
  ## Registers one websocket as a human seat-takeover connection.
  ##
  ## Deliberately NOT a roster registration: no `playerIndices` entry, no
  ## address, no token. The seat keeps its policy connection and its player
  ## index for the whole episode — the human only supplies that index's input
  ## mask once the swap lands, and watches the seat's own fogged view until
  ## it does.
  appState.globalViewers.del(websocket)
  appState.rewardViewers.del(websocket)
  discard removePlayerWebSocketState(websocket)
  appState.playerViewers[websocket] = initPlayerViewerState()
  appState.inputMasks[websocket] = 0
  appState.inputPressedMasks[websocket] = 0
  appState.lastAppliedMasks[websocket] = 0
  # Kept in playerReady only so the client's 0x85 ready packet is consumed by
  # the ready branch instead of falling through to the input decoder. The
  # readiness contract itself never sees it: resetPlayerReady/allPlayersReady
  # walk the frame's `sockets` array, which a takeover socket never enters.
  appState.playerReady[websocket] = false
  appState.takeovers[websocket] = SeatTakeover(
    seat: seat,
    requestedSeat: seat,
    name: name,
    active: false,
    cog: -1,
    observed: false,
    prevAlive: false,
    directAim: directAim,
    aimBrads: -1
  )

proc advanceSeatTakeover(
  takeover: var SeatTakeover,
  cog: int,
  cogAlive: bool,
  instant: bool = false
): bool =
  ## Advances one seat takeover by a frame; returns true on the frame the swap
  ## lands. `cog` is the seat's resolved player index (-1 when the seat has no
  ## cog right now — between matches, or before its policy has joined) and
  ## `cogAlive` is that cog's alive flag this frame.
  ##
  ## The rule, in modes that respawn: a pending takeover goes live on the
  ## cog's next false -> true `alive` edge. That is the one clean moment — the
  ## human always starts a life at spawn, and no cog is ever body-snatched
  ## mid-life. A cog that has yet to be sampled is never an edge (`observed`),
  ## so a human arriving mid-life waits out that life rather than taking the
  ## field at once.
  ##
  ## `instant` (brMode): a single-life elimination cog that is already alive
  ## on the FIRST sampled frame will never produce a false -> true edge — it
  ## only ever goes true -> false once, permanently, on elimination. Gating
  ## on the respawn edge in that mode means the takeover can never land: the
  ## human's socket is attached to the seat's view (so they see a vision
  ## cone) while the seat's input keeps reading from the policy forever (so
  ## an AI keeps driving). So in brMode, land on the very first sampled frame
  ## if the cog is alive right then — still exactly one frame late enough to
  ## avoid landing on a cog that is already dead when the human arrives (that
  ## case falls through to the ordinary edge, same as before).
  takeover.cog = cog
  takeover.cogAlive = cogAlive
  if takeover.active:
    return false
  if takeover.observed and not takeover.prevAlive and cogAlive:
    takeover.active = true
    result = true
  elif instant and not takeover.observed and cogAlive:
    takeover.active = true
    result = true
  takeover.observed = true
  takeover.prevAlive = cogAlive

proc seatWaitTicks(
  board: seq[SeatSnapshot],
  seat: int,
  preferAlive: bool = false
): int =
  ## How long a seat's cog is from its next spawn, in ticks. A cog that is UP
  ## is `int.high`: the swap lands at the next respawn, so a healthy cog is an
  ## unbounded wait, and this refuses to pretend otherwise. A seat with no cog
  ## at all is 0 — a new match lands every pending takeover at the whistle.
  ##
  ## `preferAlive` (brMode) inverts which state is "unbounded": a brMode cog
  ## that is DOWN is permanently eliminated (sim.nim's killPlayer forces
  ## lives=0, respawnTimer=0 for the rest of the round in brMode) and will
  ## never spawn again until the next full match reset, while a cog that is
  ## UP lands the swap on literally the next sampled frame via
  ## advanceSeatTakeover's `instant` branch. So in brMode, ALIVE is the
  ## near-zero wait and DOWN is the unbounded one — the exact opposite of the
  ## respawning-mode rule above.
  for entry in board:
    if entry.seat == seat:
      return
        if preferAlive:
          (if entry.alive: 0 else: int.high)
        else:
          (if entry.alive: int.high else: max(entry.respawnTimer, 0))
  0

proc migratePendingTakeovers(board: seq[SeatSnapshot], preferAlive: bool = false) =
  ## Re-points a still-PENDING takeover at whichever free seat gets it onto the
  ## field soonest.
  ##
  ## This is what turns "click play" into "play". The swap lands at a cog's next
  ## respawn, so a human handed a healthy cog waits out a whole life — an
  ## unbounded, unexplainable stall while they watch a cog they do not drive.
  ## Nobody arriving at Free Play asked for a PARTICULAR policy seat; they asked
  ## to play. So a pending takeover parks on whichever cog is already down.
  ##
  ## Only pending takeovers move — once someone is driving, the seat is theirs
  ## for good. And a takeover already parked on a DOWNED cog never moves again:
  ## that cog is about to stand up, which is the best case there is, and hopping
  ## off it for a marginally sooner one would be pure thrash.
  ##
  ## `preferAlive` (brMode): the "good landing spot" and the "keep searching"
  ## target swap places, mirroring seatWaitTicks above -- a takeover already
  ## parked on an ALIVE brMode cog is parked exactly right (the instant branch
  ## lands it on the next sampled frame) and must never be moved off it onto a
  ## cog that is down, which in brMode means permanently eliminated.
  if appState.takeovers.len == 0 or board.len == 0:
    return
  var held: seq[int] = @[]
  for _, takeover in appState.takeovers.pairs:
    held.add(takeover.seat)
  for _, takeover in appState.takeovers.mpairs:
    if takeover.active:
      continue
    if seatWaitTicks(board, takeover.seat, preferAlive) != int.high:
      continue                      # already parked on a good landing spot
    var
      bestSeat = -1
      bestWait = int.high
    for entry in board:
      let isCandidate = if preferAlive: entry.alive else: not entry.alive
      if not isCandidate or entry.seat in held:
        continue
      let wait = if preferAlive: 0 else: max(entry.respawnTimer, 0)
      if wait < bestWait:
        bestWait = wait
        bestSeat = entry.seat
    if bestSeat < 0:
      continue
    for i in 0 ..< held.len:
      if held[i] == takeover.seat:
        held[i] = bestSeat
        break
    takeover.seat = bestSeat
    # Re-sampled from scratch on the new seat: the cog is down right now, so
    # the first sample is not an edge and the swap lands on its next spawn.
    takeover.cog = -1
    takeover.observed = false
    takeover.prevAlive = false

proc landSeatTakeoversOnNewMatch() =
  ## Lands every pending takeover at a new match's opening spawn.
  ##
  ## Not redundant with the alive edge: a reset empties the roster and re-seats
  ## it inside ONE locked block, so no frame ever samples the gap and the edge
  ## alone would miss it. A new match is a fresh spawn for every cog — the
  ## cleanest handoff moment there is — so anyone still suiting up takes the
  ## field with the whistle.
  for _, takeover in appState.takeovers.mpairs:
    takeover.active = true
    takeover.observed = false
    takeover.prevAlive = false

proc registerGlobalWebSocket(websocket: WebSocket) =
  ## Registers one websocket as a global viewer connection.
  discard removePlayerWebSocketState(websocket)
  appState.rewardViewers.del(websocket)
  appState.globalViewers[websocket] = initGlobalViewerState()

proc registerRewardWebSocket(websocket: WebSocket) =
  ## Registers one websocket as a reward stream connection.
  discard removePlayerWebSocketState(websocket)
  appState.globalViewers.del(websocket)
  appState.rewardViewers[websocket] = true

proc isPlayerWebSocket(websocket: WebSocket): bool =
  ## Returns true when a websocket is exclusively a player connection.
  result =
    websocket in appState.playerViewers and
      websocket notin appState.globalViewers and
      websocket notin appState.rewardViewers and
      websocket notin appState.takeovers

proc playSeatIndex(websocket: WebSocket): int =
  ## Returns the stable configured seat for a play socket, or -1. The gate is
  ## intentionally conjunctive: season2Shell defaults on, but an all-input
  ## roster must remain on the direct-input path.
  let seat = appState.playerSlots.getOrDefault(websocket, -1)
  if appState.config.isPlaySeat(seat):
    return seat
  -1

proc applyPlayerSpriteMessage(websocket: WebSocket, data: string) =
  ## Applies one complete Sprite-protocol WebSocket message. Caller holds
  ## appState.lock; this is the unchanged legacy non-play path.
  var
    mask = appState.inputMasks.getOrDefault(websocket, 0)
    pressedMask = appState.inputPressedMasks.getOrDefault(websocket, 0)
    chatText = ""
    policyPage = ""
  appState.playerViewers[websocket].applyPlayerViewerMessage(
    data,
    mask,
    pressedMask,
    chatText,
    policyPage
  )
  appState.inputMasks[websocket] = mask
  appState.inputPressedMasks[websocket] = pressedMask
  if chatText.len > 0:
    appState.chatMessages[websocket] = chatText
  # The one-page-policy REFLASH receive arm, parked in the inbox the tick
  # loop drains. Admission remains a tick-boundary sim decision.
  if policyPage.len > 0:
    appState.policyPageFlashes[websocket] = policyPage

proc applyPlaySeatSpriteMessage(websocket: WebSocket, data: string) =
  ## Preserves the shared Sprite parser's chat and mouse behavior, but never
  ## lets embedded input or debug-sprite packets cross the play boundary.
  ## Leading forbidden packets are filtered by dispatch; this catches them
  ## behind another legal opcode in the same WebSocket message.
  let
    originalMask = appState.inputMasks.getOrDefault(websocket, 0)
    originalPressedMask =
      appState.inputPressedMasks.getOrDefault(websocket, 0)
    originalDebugCount =
      appState.playerViewers[websocket].pendingDebugSprites.len
  var hasDebugSprite = false
  for item in data.parseSpriteClientMessages():
    if item.kind == SpriteClientDebugSpriteMessage:
      hasDebugSprite = true
  var
    discardedMask = originalMask
    discardedPressedMask = originalPressedMask
    chatText = ""
    policyPage = ""
  appState.playerViewers[websocket].applyPlayerViewerMessage(
    data,
    discardedMask,
    discardedPressedMask,
    chatText,
    policyPage
  )
  if discardedMask != originalMask or
      discardedPressedMask != originalPressedMask:
    inc appState.playSpriteInputIgnored
  if hasDebugSprite:
    appState.playerViewers[websocket].pendingDebugSprites.setLen(
      originalDebugCount)
    inc appState.playSpriteDebugIgnored
  if chatText.len > 0:
    appState.chatMessages[websocket] = chatText

proc dispatchPlaySeatMessage(
  websocket: WebSocket,
  seat: int,
  data: string,
): bool =
  ## Owns the play socket's leading-byte switch. Shell framing is decoded
  ## before any Sprite parser sees the message. Uploads and calls stop here in
  ## a bounded generation-stamped queue; their consumer runs on the tick.
  result = true
  let ingressSeat = seat.playIngressSeat()
  if ingressSeat == nil:
    inc appState.playProtocolRejected
    return
  let generation = ingressSeat[].binding.generation
  case ingressSeat[].inspectPlayMessage(websocket, generation, data.len)
  of piiStale:
    return
  of piiDisconnect:
    let opcode = if data.len > 0: uint8(data[0]) else: 0'u8
    retainWireRefusal(seat, generation, opcode, data.packetIdIfPresent,
      "classification_budget_exceeded")
    return false
  of piiAllowed:
    discard
  let received = data.classifyPlaySeatMessage()
  case received.kind
  of prSprite:
    websocket.applyPlaySeatSpriteMessage(received.spriteBytes)
  of prIgnoredSpriteInput:
    inc appState.playSpriteInputIgnored
  of prIgnoredSpriteReady:
    inc appState.playSpriteReadyIgnored
  of prIgnoredSpriteDebug:
    inc appState.playSpriteDebugIgnored
  of prModuleUpload:
    let packet = received.moduleUpload
    let uploadId = packet.uploadId
    if ingressSeat[].queueUpload(websocket, generation, packet) == piqDropped:
      retainWireRefusal(seat, generation, OpModuleUpload, uploadId,
        "per_tick_upload_cap")
  of prPlayCall:
    let packet = received.playCall
    let proposalId = packet.proposalId
    if ingressSeat[].queueCall(websocket, generation, packet) == piqDropped:
      retainWireRefusal(seat, generation, OpPlayCall, proposalId,
        "per_tick_call_cap")
  of prStatusAck:
    ingressSeat[].queueStatusAck(
      websocket, generation, received.statusAck)
  of prLobbyChat:
    if playReceiveConsumers.lobbyChat == nil:
      inc appState.playProtocolRejected
    else:
      playReceiveConsumers.lobbyChat(websocket, seat, received.lobbyChat)
  of prBallotCast:
    if playReceiveConsumers.ballotCast == nil:
      inc appState.playProtocolRejected
    else:
      playReceiveConsumers.ballotCast(websocket, seat, received.ballotCast)
  of prRejected:
    inc appState.playProtocolRejected
    let opcode = if data.len > 0: uint8(data[0]) else: 0'u8
    retainWireRefusal(seat, generation, opcode, data.packetIdIfPresent,
      "malformed_packet")

proc drainPlayIngressAtTickBoundary*(uploadWindowClosed = false) =
  ## Moves the bounded socket queues onto the game thread. Generation checks
  ## happen inside the drain, so a replaced socket can never hand work across
  ## the lane-C seam even if its message was queued first.
  var
    acknowledgements: seq[tuple[seat: int, ack: PlayIngressAck[WebSocket]]]
    admitted: seq[tuple[seat: int, message: PlayIngressMessage[WebSocket]]]
    rejected = 0
  {.gcsafe.}:
    withLock appState.lock:
      ensurePlayIngressConfigured()
      for seat in 0 ..< appState.playIngress.len:
        let ack = appState.playIngress[seat].takeStatusAck()
        if ack.present:
          acknowledgements.add((seat, ack))
  for item in acknowledgements:
    if playReceiveConsumers.statusAck == nil:
      inc rejected
    else:
      let feedback = playReceiveConsumers.statusAck(
        item.ack.socket, item.seat, item.ack.packet)
      {.gcsafe.}:
        withLock appState.lock:
          if item.seat >= 0 and item.seat < appState.playIngress.len:
            let errors =
              appState.playIngress[item.seat].applyPlayIngressFeedback(feedback)
            appState.playIngressFeedbackErrors.saturatingAdd(errors)
  {.gcsafe.}:
    withLock appState.lock:
      for seat in 0 ..< appState.playIngress.len:
        var drained = appState.playIngress[seat].drainPlayIngress(
          uploadWindowClosed)
        rejected += drained.rejected
        for refusal in drained.refusals:
          let opcode =
            if refusal.kind == pirUpload: OpModuleUpload else: OpPlayCall
          retainWireRefusal(seat, refusal.generation, opcode, refusal.id,
            refusal.reason)
        for message in drained.admitted:
          admitted.add((seat, message))
  for item in admitted:
    case item.message.kind
    of pimUpload:
      if playReceiveConsumers.moduleUpload == nil:
        inc rejected
      else:
        playReceiveConsumers.moduleUpload(
          item.message.socket, item.seat, item.message.generation,
          item.message.upload)
    of pimCall:
      if playReceiveConsumers.playCall == nil:
        inc rejected
      else:
        playReceiveConsumers.playCall(
          item.message.socket, item.seat, item.message.generation,
          item.message.call)
  if rejected > 0:
    {.gcsafe.}:
      withLock appState.lock:
        appState.playProtocolRejected += rejected

proc drainPlayIngressAtTickBoundary*(episode: var ShellEpisode;
                                     tick: uint32;
                                     uploadWindowClosed = false) =
  ## Production-only scoped ownership bridge. Registered consumers run
  ## synchronously inside this drain; the pointer is never visible to the
  ## socket threads and never survives the call.
  doAssert activeShellEpisode == nil
  activeShellEpisode = episode.addr
  activeShellTick = tick
  try:
    drainPlayIngressAtTickBoundary(uploadWindowClosed)
  finally:
    activeShellEpisode = nil
    activeShellTick = 0

proc applyPlayIngressFeedback*(seat: int, feedback: PlayIngressFeedback) =
  ## Reverse half of the registered lane-B/lane-C seam. Async compile/runtime
  ## work may retire capacity after the receive callback has returned; it
  ## reports that fact here without importing either lane into the other.
  {.gcsafe.}:
    withLock appState.lock:
      let ingressSeat = seat.playIngressSeat()
      if ingressSeat == nil:
        appState.playIngressFeedbackErrors.saturatingAdd(1)
        return
      let errors = ingressSeat[].applyPlayIngressFeedback(feedback)
      appState.playIngressFeedbackErrors.saturatingAdd(errors)

proc queuePlayCallRecord*(record: PlayCallRecord) {.gcsafe.} =
  ## Lane C reports one accepted, fully identified call. The game thread owns
  ## file order and drains this queue only at a tick boundary.
  {.gcsafe.}:
    withLock appState.lock:
      appState.pendingPlayCallRecords.add(record)

proc notePlayCallReplayIdentityError(seat: int) {.gcsafe.} =
  {.gcsafe.}:
    withLock appState.lock:
      appState.playIngressFeedbackErrors.saturatingAdd(1)
      if seat >= 0 and seat < appState.playIngress.len:
        appState.playIngress[seat].notePlayIngressFeedbackError()

proc queueAcceptedPlayCallIdentity(expectedSeat: int;
    identity: Option[ShellCallReplayIdentity];
    replayTimeMs: uint32): bool {.gcsafe.} =
  ## Lane C owns accepted-call identity; lane B owns time and file order.
  ## Never reconstruct canonical bytes, hashes, or entry identities here.
  {.cast(gcsafe).}:
    if identity.isNone:
      notePlayCallReplayIdentityError(expectedSeat)
      return false
    let accepted = identity.get
    var validSeat = false
    withLock appState.lock:
      validSeat = expectedSeat >= 0 and
        expectedSeat < appState.playIngress.len and
        int(accepted.seat) == expectedSeat and
        appState.config.isPlaySeat(expectedSeat)
    if not validSeat:
      notePlayCallReplayIdentityError(expectedSeat)
      return false
    queuePlayCallRecord(accepted.toPlayCallRecord(replayTimeMs))
    true

proc queueShellAnnotation*(annotation: ShellAnnotation) =
  ## Async runtime annotations cross the same narrow game-thread seam.
  {.gcsafe.}:
    withLock appState.lock:
      appState.pendingShellAnnotations.add(annotation)

proc queueLobbyChatRecord*(record: LobbyChatRecord) =
  ## Maxwell's accepted lobby message enters the replay only after sim-side
  ## admission has assigned its global ordinal.
  {.gcsafe.}:
    withLock appState.lock:
      appState.pendingLobbyChatRecords.add(record)

proc drainProductionLobbyChats(sim: var SimServer) =
  ## Applies §9.2 on the game thread. The sim owns the five-step canonical
  ## text algorithm, phase gate, spacing, cap, and global ordinal.
  var pending: seq[PendingLobbyChat]
  {.gcsafe.}:
    withLock appState.lock:
      pending = move(appState.pendingLobbyChats)
      appState.pendingLobbyChats = @[]
  for item in pending:
    var playerIndex = -1
    {.gcsafe.}:
      withLock appState.lock:
        if item.seat >= 0 and item.seat < appState.playIngress.len and
            appState.playIngress[item.seat].binding.admits(
              item.websocket, item.generation):
          playerIndex = appState.seatPlayerIndices[item.seat]
    if playerIndex < 0:
      continue
    let outcome = sim.applyLobbyChat(playerIndex, item.packet.text)
    if not outcome.ok:
      {.gcsafe.}:
        withLock appState.lock:
          if item.seat < appState.playOutbound.len:
            appState.playOutbound[item.seat].noteDroppedChat()
            discard appState.playOutbound[item.seat].retainCallRefusal(
              item.generation, 0, "lobby_chat:" & $outcome.reason)
      continue
    let record = LobbyChatRecord(
      replayTimeMs: tickTime(sim.tickCount), ordinal: outcome.ordinal,
      seat: uint8(item.seat),
      team: uint8(ord(sim.teamForSlot(item.seat))), text: item.packet.text)
    {.gcsafe.}:
      withLock appState.lock:
        appState.lobbyTranscript.add(record)
        appState.lobbyTranscriptTicks.add(uint32(sim.tickCount))
        appState.pendingLobbyChatRecords.add(record)

proc drainProductionBallotCasts(sim: var SimServer) =
  ## MAP VOTE: applies queued 0xA4 sends on the game thread, inside the
  ## same pre-step block that drains lobby chat, stamping every FRESH
  ## accept as a `0x17` kind-0 record at tickTime(sim.tickCount) — the
  ## exact tick playback re-applies it on (replays.applyReplayEvents), so
  ## the tally, the early-resolution tick and the winner-map install all
  ## reproduce. The sim owns admission (window, castId dedup, rate cap,
  ## spacing) and the global ordinal; a refused cast leaves a
  ## "ballot_cast:<reason>" refusal on the seat's status channel. Once
  ## resolution has run (inside stepLobby), the kind-1 record is emitted
  ## exactly once, right here, ordinal voteOrdinal + 1 — the contract
  ## tests/test_vote_phase.nim pins.
  var pending: seq[PendingBallotCast]
  {.gcsafe.}:
    withLock appState.lock:
      pending = move(appState.pendingBallotCasts)
      appState.pendingBallotCasts = @[]
  for item in pending:
    var playerIndex = -1
    {.gcsafe.}:
      withLock appState.lock:
        if item.seat >= 0 and item.seat < appState.playIngress.len and
            appState.playIngress[item.seat].binding.admits(
              item.websocket, item.generation):
          playerIndex = appState.seatPlayerIndices[item.seat]
    if playerIndex < 0:
      continue
    let outcome = sim.applyBallotCast(
      playerIndex, item.packet.castId, item.packet.option)
    if not outcome.ok:
      {.gcsafe.}:
        withLock appState.lock:
          if item.seat < appState.playOutbound.len:
            discard appState.playOutbound[item.seat].retainCallRefusal(
              item.generation, 0, "ballot_cast:" & $outcome.reason)
      continue
    if not outcome.fresh:
      continue   # idempotent resend: nothing new to record (§2).
    let record = BallotRecord(kind: brkCast,
      replayTimeMs: tickTime(sim.tickCount), ordinal: outcome.ordinal,
      seat: uint8(item.seat),
      team: uint8(ord(sim.teamForSlot(item.seat))),
      option: item.packet.option)
    {.gcsafe.}:
      withLock appState.lock:
        appState.pendingBallotRecords.add(record)
  if sim.voteResolved:
    {.gcsafe.}:
      withLock appState.lock:
        if not appState.voteResolutionRecorded:
          appState.voteResolutionRecorded = true
          appState.pendingBallotRecords.add(BallotRecord(kind: brkResolved,
            replayTimeMs: tickTime(sim.tickCount),
            ordinal: sim.voteOrdinal + 1,
            category: sim.voteCategory,
            tieBreakDrawn: (if sim.voteTieBreakDrawn: 1'u8 else: 0'u8),
            finalOption: sim.voteFinalOption))

proc playContextBytes*(sim: SimServer; config: GameConfig; seat: int): string =
  ## Exported 2026-09-05 so tools/verify_br_solo16.nim can exercise the exact
  ## call this proc's own callsite (pumpPlayOutbound) makes when a play seat
  ## connects live -- the path that raised ValueError for solo BR seats
  ## before the duo_partner invariant was relaxed (src/shell/view.nim,
  ## src/shell/binary_view.nim). No behavior change.
  var source = PlayContextSource(
    mode: if config.brMode: gmBr else: gmCtf,
    mapName: if sim.gameMap.name.len > 0: sim.gameMap.name else: config.mapPath,
    mapWidth: sim.gameMap.width, mapHeight: sim.gameMap.height,
    selfSeat: seat, selfTeam: config.slots[seat].team,
    gunRange: config.gunRange, viewInterval: config.viewIntervalTicks)
  var controls: seq[SlotControl]
  var teams: seq[Team]
  var names: seq[string]
  for index, slot in config.slots:
    controls.add(slot.control)
    teams.add(slot.team)
    names.add(slot.name)
    if config.brMode and index != seat and slot.team == source.selfTeam:
      source.duoPartner = some(index)
  # Same builder as episode.nim's contextRoster, so the socket 0xB0 and the
  # play_init context cannot drift (view.playContextRosterRows).
  source.roster = playContextRosterRows(controls, teams, names)
  buildPlayContext(source)

proc playSocketStillCurrent(seat: int; websocket: WebSocket;
                            generation: uint64): bool =
  seat >= 0 and seat < appState.playOutbound.len and
    appState.playOutbound[seat].generation == generation and
    appState.playOutbound[seat].currentSocket == some(websocket)

proc sendCurrentPlayPacket(seat: int; websocket: WebSocket;
                           generation: uint64; payload: sink string): bool =
  ## Admission into Mummy's bounded pipeline happens while the generation is
  ## still current. False is counted; bytes are never copied into another
  ## application queue.
  {.gcsafe.}:
    withLock appState.lock:
      if not playSocketStillCurrent(seat, websocket, generation):
        return false
      result = websocket.trySendPlaySocket(move(payload))
      if not result:
        appState.playOutbound[seat].noteSendRefused()

proc pumpPlayOutbound(sim: SimServer; config: GameConfig;
                      episode: ShellEpisode) =
  ## Sends context, transcript replay/live chat, then at most one view per
  ## seat. Transcript cursors advance only after transport admission.
  if not config.isPlaySeatEpisode():
    return
  let tick = uint32(max(0, sim.tickCount))
  for seat in 0 ..< config.slots.len:
    if config.slots[seat].control != scPlay:
      continue
    var outbound: PlayOutboundSeat[WebSocket]
    var ingress: PlayIngressSnapshot
    {.gcsafe.}:
      withLock appState.lock:
        if seat >= appState.playOutbound.len:
          continue
        outbound = appState.playOutbound[seat]
        ingress = appState.playIngress[seat].snapshot()
    let socketOption = outbound.currentSocket
    if socketOption.isNone:
      continue
    let websocket = socketOption.get
    let generation = outbound.generation

    if outbound.contextPending:
      let episodeRecovery = episode.shellRecovery(seat)
      let recovery = PlayContextRecovery(
        generation: generation, callNumber: episodeRecovery.callNumber,
        uploadIdFloor: ingress.uploadIdFloor,
        proposalIdFloor: ingress.proposalIdFloor,
        modulesLeft: max(0,
          MaxModulesPerSeatPerEpisode - ingress.admittedModules),
        uploadBytesLeft: max(0,
          MaxUploadBytesPerSeatPerEpisode - int(ingress.admittedUploadBytes)),
        ackMark: outbound.ackMark,
        lobbyTranscriptMark: outbound.lobbyTranscriptMark,
        call: episodeRecovery.call,
        playbook: episodeRecovery.playbook)
      let payload = encodePacket(PlayContextPacket(
        control: controlContextEnvelope(recovery),
        context: sim.playContextBytes(config, seat)))
      if not sendCurrentPlayPacket(seat, websocket, generation, payload):
        continue
      {.gcsafe.}:
        withLock appState.lock:
          if playSocketStillCurrent(seat, websocket, generation):
            appState.playOutbound[seat].markContextSent()

    var sentTranscript = 0
    while sentTranscript < ReplayPumpBatch:
      var record: LobbyChatRecord
      var recordTick: uint32
      var present = false
      {.gcsafe.}:
        withLock appState.lock:
          if not playSocketStillCurrent(seat, websocket, generation):
            break
          let cursor = appState.playOutbound[seat].transcriptCursor
          if cursor < uint64(appState.lobbyTranscript.len):
            record = appState.lobbyTranscript[int(cursor)]
            recordTick = appState.lobbyTranscriptTicks[int(cursor)]
            present = true
      if not present:
        break
      let payload = encodePacket(LobbyChatBroadcastPacket(
        ordinal: record.ordinal, tick: recordTick,
        seat: record.seat, team: record.team, text: record.text))
      if not sendCurrentPlayPacket(seat, websocket, generation, payload):
        break
      {.gcsafe.}:
        withLock appState.lock:
          if playSocketStillCurrent(seat, websocket, generation):
            appState.playOutbound[seat].advanceTranscript()
      inc sentTranscript

    var current: PlayOutboundSeat[WebSocket]
    var transcriptLength = 0
    {.gcsafe.}:
      withLock appState.lock:
        if not playSocketStillCurrent(seat, websocket, generation):
          continue
        current = appState.playOutbound[seat]
        transcriptLength = appState.lobbyTranscript.len
        ingress = appState.playIngress[seat].snapshot()
    if not current.shouldSendView(tick, config.viewIntervalTicks):
      continue
    let ingressCounters = PlayControlCounters(
      droppedUploads: ingress.counters.droppedUploads,
      droppedCalls: ingress.counters.droppedCalls,
      backpressure: ingress.counters.backpressure)
    var viewBytes = ""
    var playerIndex = -1
    {.gcsafe.}:
      withLock appState.lock:
        if seat < appState.seatPlayerIndices.len:
          playerIndex = appState.seatPlayerIndices[seat]
    if not current.hasTranscriptPending(transcriptLength) and
        sim.phase == Playing:
      if playerIndex >= 0 and playerIndex < sim.players.len and
          sim.players[playerIndex].alive:
        # Socket copy = JSON (0xB1 wire contract); the guest's PV1 binary
        # frame never crosses the websocket (see shellSocketViewBytes).
        viewBytes = episode.shellSocketViewBytes(seat, tick)
    let payload = encodePacket(PlayViewPacket(
      tick: tick, control: current.controlViewEnvelope(ingressCounters),
      view: viewBytes))
    if sendCurrentPlayPacket(seat, websocket, generation, payload):
      {.gcsafe.}:
        withLock appState.lock:
          if playSocketStillCurrent(seat, websocket, generation):
            appState.playOutbound[seat].markViewSent(tick)

proc drainShellReplayRecords(
  replayWriter: var CtfReplayWriter,
  sim: var SimServer,
  replayTimeMs: uint32,
) =
  ## One format-2 batch in the P5a total order: lifecycle (phase 1), lobby
  ## transcript (phase 3), then calls (phase 4). Annotation ticks form their
  ## own per-seat stream and do not participate in replay-time ordering.
  var
    lifecycle: seq[PendingLifecycleRecord]
    calls: seq[PlayCallRecord]
    annotations: seq[ShellAnnotation]
    transcript: seq[LobbyChatRecord]
    ballots: seq[BallotRecord]
  {.gcsafe.}:
    withLock appState.lock:
      lifecycle = move(appState.pendingLifecycleRecords)
      calls = move(appState.pendingPlayCallRecords)
      annotations = move(appState.pendingShellAnnotations)
      transcript = move(appState.pendingLobbyChatRecords)
      ballots = move(appState.pendingBallotRecords)
      appState.pendingLifecycleRecords = @[]
      appState.pendingPlayCallRecords = @[]
      appState.pendingShellAnnotations = @[]
      appState.pendingLobbyChatRecords = @[]
      appState.pendingBallotRecords = @[]
  for pending in lifecycle:
    replayWriter.writeLifecycle(LifecycleRecord(
      kind: pending.kind,
      replayTimeMs: replayTimeMs,
      seat: uint8(pending.seat)))
    case pending.kind
    of lrDisconnect, lrKick:
      replayWriter.writeInputMaskChange(
        replayTimeMs, pending.playerIndex, 0)
    of lrRebind:
      let accountIndex = sim.rewardAccountForPlayer(pending.playerIndex)
      if accountIndex >= 0:
        sim.rewardAccounts[accountIndex].abandoned = false
  for record in transcript:
    replayWriter.writeLobbyChat(record)
  for record in ballots:
    # Same phase-3 batch as the transcript (0x17's placement rule mirrors
    # 0x13's); ordinal order within the batch is queue order.
    replayWriter.writeBallot(record)
  for record in calls:
    replayWriter.writePlayCall(record)
  for annotation in annotations:
    replayWriter.writeAnnotation(annotation)

proc removeWebSocketState(websocket: WebSocket): int =
  ## Removes websocket-owned state and returns its former player index.
  if websocket in appState.globalViewers:
    appState.globalViewers.del(websocket)
  if websocket in appState.rewardViewers:
    appState.rewardViewers.del(websocket)
  result = removePlayerWebSocketState(websocket)

proc retainShellSocketLoss(
  sim: var SimServer,
  websocket: WebSocket,
  prevInputs: var seq[InputState],
): bool =
  ## Applies the shell episode's stable-row rule. Caller holds appState.lock.
  if not appState.config.isPlaySeatEpisode():
    return false
  let seat = appState.playerSlots.getOrDefault(websocket, -1)
  if seat < 0 or seat >= appState.config.slots.len:
    return false
  let playerIndex = appState.playerIndices.getOrDefault(
    websocket, appState.seatPlayerIndices[seat])
  if playerIndex >= 0 and playerIndex < UnresolvedPlayerIndex:
    appState.seatPlayerIndices[seat] = playerIndex
  if appState.config.slots[seat].control == scPlay:
    let ingressSeat = seat.playIngressSeat()
    if ingressSeat != nil:
      ingressSeat[].playerIndex = playerIndex
    discard removeWebSocketState(websocket)
    return true

  # A socket can vanish before strict slot-sequential admission creates its
  # sim row. There is no stable row or replay join to tombstone in that case;
  # discard only the pending registration and allow a fresh join later.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    discard removeWebSocketState(websocket)
    return true

  if appState.seatTombstones[seat].disconnect(sim.phase != Lobby):
    sim.recordGameAbandon(playerIndex)
    if playerIndex >= 0 and playerIndex < prevInputs.len:
      prevInputs[playerIndex] = InputState()
    appState.pendingLifecycleRecords.add(PendingLifecycleRecord(
      kind: lrDisconnect, seat: seat, playerIndex: playerIndex))
  discard removeWebSocketState(websocket)
  true

proc terminallyTombstoneShellSeat(
  sim: var SimServer,
  websocket: WebSocket,
  prevInputs: var seq[InputState],
): bool =
  ## Applies an administrative kick without deleting or reindexing the row.
  ## Caller holds appState.lock.
  if not appState.config.isPlaySeatEpisode():
    return false
  let seat = appState.playerSlots.getOrDefault(websocket, -1)
  if seat < 0 or seat >= appState.seatTombstones.len:
    return false
  let playerIndex = appState.playerIndices.getOrDefault(
    websocket, appState.seatPlayerIndices[seat])
  if not appState.seatTombstones[seat].kick(sim.phase != Lobby):
    return true
  if playerIndex >= 0 and playerIndex < UnresolvedPlayerIndex:
    appState.seatPlayerIndices[seat] = playerIndex
  if playerIndex < 0 or playerIndex >= sim.players.len:
    discard removeWebSocketState(websocket)
    return true
  sim.recordGameAbandon(playerIndex)
  if playerIndex >= 0 and playerIndex < prevInputs.len:
    prevInputs[playerIndex] = InputState()
  appState.pendingLifecycleRecords.add(PendingLifecycleRecord(
    kind: lrKick, seat: seat, playerIndex: playerIndex))
  if appState.config.isPlaySeat(seat) and playReceiveConsumers.kick != nil:
    for annotation in playReceiveConsumers.kick(seat):
      appState.pendingShellAnnotations.add(annotation)
  discard removeWebSocketState(websocket)
  true

proc removePlayer(sim: var SimServer, websocket: WebSocket) =
  ## Removes a websocket and keeps live player indices consistent.
  let removedIndex = removeWebSocketState(websocket)
  if removedIndex >= 0 and removedIndex < sim.players.len:
    sim.removePlayerAt(removedIndex)
    # Re-index every OTHER socket that already held a resolved array
    # position -- but a socket still waiting on admission is tagged
    # UnresolvedPlayerIndex, not a real position, and that sentinel is
    # always > removedIndex. Decrementing it here (the bug: no exclusion)
    # turns it into a value that is neither a valid index nor the pending
    # sentinel, so the newSockets scan (`== UnresolvedPlayerIndex`) can
    # never find it again -- the socket stays connected forever but is
    # permanently invisible to admission. This is the lobby-fill wedge:
    # any one disconnect mid-fill orphans every OTHER still-pending
    # socket in the same pass, and nothing ever re-scans them.
    for ws, value in appState.playerIndices.mpairs:
      if value > removedIndex and value != UnresolvedPlayerIndex:
        dec value

proc admitPendingJoins(
  sim: var SimServer,
  pendingPlayers: var seq[PendingPlayerJoin],
  socketsToClose: var seq[WebSocket],
  liveOverlays: var seq[DebugOverlay]
): seq[PendingPlayerJoin] =
  ## Admits pending joins in resolved-slot order (the shared core of the main
  ## loop's and the reset path's join resolution): sorts candidates, seats
  ## every join whose slot is exactly the next open one, records the seat in
  ## appState.playerIndices/playerSlots, and grows liveOverlays to the roster.
  ## Returns the joins that were seated so each caller can run its own
  ## bookkeeping (replay join records vs. input-mask resets). Caller holds
  ## appState.lock.
  pendingPlayers.sort(comparePendingPlayerJoins)
  for join in pendingPlayers:
    if join.slotIndex != sim.nextPlayerSlot():
      continue
    try:
      appState.playerIndices[join.websocket] = sim.addPlayer(
        join.address,
        join.requestedSlot,
        join.token
      )
    except CtfError:
      sim.removePlayer(join.websocket)
      socketsToClose.add(join.websocket)
      continue
    appState.playerSlots[join.websocket] =
      sim.players[appState.playerIndices[join.websocket]].joinOrder
    while liveOverlays.len < sim.players.len:
      liveOverlays.add(DebugOverlay())
    result.add(join)

proc cleanPlayerName(name: string): string =
  ## Returns a protocol-safe player display name.
  result = name.strip()
  for ch in result.mitems:
    if ch.isSpaceAscii:
      ch = '_'

proc cleanGuestName*(name: string): string =
  ## Returns a display-safe guest name. Unlike `cleanPlayerName` this keeps
  ## the space — "Green Rookie" is the paintball register the app generates,
  ## and this name never enters the sim, the wire, or the replay: it is seat
  ## metadata the server reports back so a surface can say who is suiting up.
  for ch in name.strip():
    if result.len >= 24:
      break
    if ch.ord >= 32 and ch.ord < 127 and ch notin {'"', '<', '>', '&', '\\'}:
      result.add ch

proc generatedPlayerName*(index: int): string =
  ## Returns the generated display name for an anonymous player index.
  "Player" & $index

proc anonymousPlayerIdentity*(
  nextIndex: var int,
  existingNames: openArray[string]
): string =
  ## Returns a unique generated identity for one nameless player.
  if nextIndex <= 0:
    nextIndex = 1
  while true:
    result = generatedPlayerName(nextIndex)
    inc nextIndex
    var taken = false
    for name in existingNames:
      if name == result:
        taken = true
        break
    if not taken:
      return

proc nextAnonymousPlayerIdentity(): string =
  ## Returns a unique generated identity from current server state.
  {.gcsafe.}:
    withLock appState.lock:
      var existingNames: seq[string] = @[]
      for _, address in appState.playerAddresses.pairs:
        existingNames.add(address)
      for identity in appState.kickedIdentities.keys:
        existingNames.add(identity)
      result = anonymousPlayerIdentity(
        appState.nextAnonymousPlayer,
        existingNames
      )

proc playerIdentity(request: Request, slot: int, token: string): string =
  ## Returns the websocket player identity for rewards and displays.
  let name = request.queryParams.getOrDefault("name", "").cleanPlayerName()
  if name.len > 0:
    return name
  {.gcsafe.}:
    withLock appState.lock:
      result = appState.config.configuredPlayerName(slot, token)
      if result.len > 0:
        return
  result = nextAnonymousPlayerIdentity()

proc playerSlot(request: Request): int =
  ## Returns the requested player slot or -1 for automatic assignment.
  let text = request.queryParams.getOrDefault("slot", "").strip()
  if text.len == 0:
    return -1
  try:
    result = parseInt(text)
  except ValueError:
    return MaxPlayers
  if result < 0 or result >= MaxPlayers:
    return MaxPlayers

proc playerToken(request: Request): string =
  ## Returns the player join token.
  request.queryParams.getOrDefault("token", "").strip()

proc playerUpgradeUsesPlaySeatTransport*(config: GameConfig, slot: int): bool =
  ## Chooses the larger socket caps only for a configured play seat under the
  ## conjunctive Season 2 gate. Limits are transport caps, not admission.
  config.isPlaySeat(slot)

proc controlHeaders(): HttpHeaders =
  ## Returns headers for admin-panel control requests.
  result["Content-Type"] = "text/plain; charset=utf-8"
  result["Cache-Control"] = "no-cache"
  result["Access-Control-Allow-Origin"] = "*"
  result["Access-Control-Allow-Methods"] = "POST, OPTIONS"
  result["Access-Control-Allow-Headers"] = "Content-Type"

proc respondControl(request: Request, status: int, body: string) =
  ## Sends a plain text control response.
  request.respond(status, controlHeaders(), body)

proc replayControlsDisabled(): bool =
  ## Returns true when live match controls are disabled.
  {.gcsafe.}:
    withLock appState.lock:
      result = appState.replayLoaded

proc replayServerModeEnabled(): bool =
  ## Returns true when the process is serving Coworld replay sessions.
  {.gcsafe.}:
    withLock appState.lock:
      result = appState.replayServerMode

proc disconnectWebSocket(websocket: WebSocket) =
  ## Tears down a player connection immediately.
  when defined(posix):
    let fields = cast[WebSocketSocketFields](websocket)
    discard shutdown(fields.clientSocket, SHUT_RDWR)
  else:
    websocket.close()

proc gracefulCloseSocket(websocket: WebSocket) {.gcsafe.} =
  ## The real close action `closePlayerSocketsPromptly` uses in production:
  ## mummy's own queued, handshake-respecting close (see the proc's own
  ## doc comment for why this — not `disconnectWebSocket`'s raw SHUT_RDWR
  ## — is the one that cannot drop an already-queued frame). Broken out to
  ## a plain top-level proc, rather than inlined, so a test can substitute
  ## a spy in its place and assert exactly which sockets this call site
  ## reaches, without needing a live mummy connection behind each one.
  websocket.close()

proc closePlayerSocketsPromptly(
  sockets: seq[WebSocket],
  takeoverSockets: seq[WebSocket],
  closeSocket: proc(websocket: WebSocket) {.gcsafe.} = gracefulCloseSocket
) =
  ## Certification headroom fix (2026-08-31): a platform certification run
  ## polls the PLAYER pod's process exit with a bounded budget after the
  ## game concludes. A bundled baseline player only exits once its
  ## websocket errors (players/baseline/baseline.nim: the `except` branch
  ## that calls artFlush() then quit(0)), so how soon the SERVER closes
  ## that socket after results is exactly the certification's headroom.
  ##
  ## The `ShutdownGraceSeconds` window this runs ahead of exists for the
  ## httpServer's /healthz and /global HTTP polling (see the comment at its
  ## use site) — NOT to give a human a longer look at the endcard.
  ## client/player_client.html's onclose handler confirms this: it leaves
  ## the last-rendered frame on screen and only relabels the status line
  ## ("reconnecting..." then "disconnected..."), it never blanks the
  ## canvas. And by the time this proc runs, this tick's final frame
  ## (carrying the endcard/results state) has already been queued —
  ## via `sockets[i].send(...)` / `takeoverSockets[i].send(...)` for
  ## sprite clients, and via `pumpPlayOutbound`'s `trySendPlaySocket`
  ## for play seats (which `playSocketFlags` excludes from the sprite
  ## send loop) — earlier in this same iteration; mummy's
  ## `WebSocket.close()` drains the queued messages before it starts
  ## the close handshake (see mummy.nim `proc close*`), so delivery
  ## ordering holds for both socket kinds. Only the gameplay
  ## sockets close early: spectators (`globalViewers`) and reward
  ## observers (`rewardViewers`) are untouched and keep the full grace
  ## period, same as httpServer's HTTP routes.
  for websocket in sockets:
    closeSocket(websocket)
  for websocket in takeoverSockets:
    closeSocket(websocket)

proc evictSeatTakeover(seat: int) =
  ## Drops whichever websocket currently holds `seat`'s takeover, if any.
  ##
  ## This is the RESUME half of a reload: a browser tab that closes and
  ## reopens (same seat, same token) fires its new /takeover upgrade on a
  ## worker thread that can easily win the race against this process's own
  ## cleanup of the OLD socket -- that cleanup is a once-per-tick affair
  ## (the `closedSockets` drain, main loop), while a page reload's new
  ## connection can land within the same tick the old one's close event is
  ## still queued. Before this proc existed, `takeoverSeatTaken` saw the
  ## stale entry as still live and `takeoverRejection` refused the reconnect
  ## outright (403, at the WS upgrade -- before this engine ever gets a
  ## chance to hand the new socket its one-time arena init), stranding the
  ## reload on the client's blind ~2s retry (see player_client.html's own
  ## comment on that retry: "the SAME identity/slot/token would happily be
  ## re-admitted a moment later" -- true only once this proc closes the gap).
  ##
  ## Callers gate this on the reconnecting request already having proven it
  ## holds the seat's own pinned token (see the call site) -- an UNTOKENED
  ## seat has no secret to check, so it keeps the old first-come-first-served
  ## exclusivity and never reaches here.
  ##
  ## Deliberately drops only the BOOKKEEPING, never calls disconnectWebSocket
  ## on the stale entry: that proc shuts down a raw OS socket FD by number
  ## (WebSocketSocketFields.clientSocket), and the whole reason this websocket
  ## is "stale" is that its underlying connection is already closing or
  ## closed on the client end -- exactly the condition under which the OS is
  ## most likely to have ALREADY recycled that FD number for the brand-new
  ## incoming connection this proc is trying to admit. Shutting it down here
  ## risked shutting down the NEW socket instead (measured: intermittently
  ## reproduced as "Connection closed before receiving a handshake response"
  ## on the reconnecting client). Dropping the state is sufficient: the stale
  ## socket, real or already-gone, simply stops appearing in any per-tick
  ## loop (sockets/takeoverSockets are rebuilt from these tables every tick),
  ## so it is silently retired either way, and its own eventual close event
  ## (if it ever arrives) finds nothing left to clean up.
  var stale: seq[WebSocket] = @[]
  for websocket, takeover in appState.takeovers.pairs:
    if takeover.seat == seat:
      stale.add(websocket)
  for websocket in stale:
    discard removePlayerWebSocketState(websocket)

proc identityIsKicked(identity: string): bool =
  ## Returns true when an identity is blocked from rejoining this match.
  let rewardIdentity = identity.rewardAddress()
  {.gcsafe.}:
    withLock appState.lock:
      result =
        identity in appState.kickedIdentities or
        rewardIdentity in appState.kickedIdentities

proc respondKicked(request: Request) =
  ## Rejects a kicked player before upgrading to a WebSocket.
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain; charset=utf-8"
  headers["Cache-Control"] = "no-cache"
  headers["Connection"] = "close"
  request.respond(409, headers, "player was kicked\n")

proc respondReplayRequestError(request: Request, status: int, body: string) =
  ## Rejects a replay websocket request before upgrade.
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain; charset=utf-8"
  headers["Cache-Control"] = "no-cache"
  headers["Connection"] = "close"
  request.respond(status, headers, body)

proc respondForbiddenWebSocket(request: Request, reason: string) =
  ## Rejects a forbidden websocket request before upgrading.
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain; charset=utf-8"
  headers["Cache-Control"] = "no-cache"
  headers["Connection"] = "close"
  request.respond(403, headers, reason & "\n")

proc hasPlayerCredentialParams*(name, slot, token: string): bool =
  ## Returns true when query fields identify a player connection.
  name.strip().len > 0 or slot.strip().len > 0 or token.strip().len > 0

proc hasPlayerCredentialParams(request: Request): bool =
  ## Returns true when a websocket request carries player credentials.
  hasPlayerCredentialParams(
    request.queryParams.getOrDefault("name", ""),
    request.queryParams.getOrDefault("slot", ""),
    request.queryParams.getOrDefault("token", "")
  )

proc respondForbiddenViewer(request: Request) =
  ## Rejects a viewer websocket request with player credentials.
  request.respondForbiddenWebSocket(
    "Viewer websocket cannot include player name, slot, or token."
  )

proc configuredPlayerJoinError(
  config: GameConfig,
  address: string,
  slot: int,
  token: string
): string =
  ## Returns a rejection reason for bad configured roster credentials.
  if config.playerJoinAllowed(address, slot, token):
    return ""
  if slot >= MaxPlayers:
    return "Player slot must be between 0 and " & $(MaxPlayers - 1) & "."
  if slot >= config.slots.len:
    if config.closedRoster:
      return "Player slot is outside configured roster."
    return ""
  if slot >= 0 and config.slots[slot].token.len > 0 and
      token != config.slots[slot].token:
    return "Player token does not match configured slot " & $slot & "."
  "Player credentials do not match configured roster."

proc replayRequestUri(request: Request): string =
  ## Returns the replay artifact URI requested by a Coworld replay client.
  request.queryParams.getOrDefault("uri", "").strip()

proc replayUriKnown(uri: string): bool =
  ## Returns true when this URI is queued, loading, or already active.
  if uri.len == 0:
    return false
  {.gcsafe.}:
    withLock appState.lock:
      result =
        uri == appState.pendingReplayUri or
        uri == appState.loadingReplayUri or
        uri == appState.currentReplayUri

proc queueReplayUri(uri: string) =
  ## Queues a replay switch once, even when HTML and websocket requests repeat it.
  if uri.len == 0:
    return
  {.gcsafe.}:
    withLock appState.lock:
      if uri != appState.pendingReplayUri and
          uri != appState.loadingReplayUri and
          uri != appState.currentReplayUri:
        appState.pendingReplayUri = uri

proc recordStartupReplayUri(loaded: bool) =
  ## Records the COGAME_LOAD_REPLAY_URI the process booted with as the active
  ## replay URI. readRuntimeConfig downloads that artifact and drops the URI,
  ## so without this a /client/replay or websocket request naming the same
  ## URI would queue a full reload (fetch + map regen + keyframes) of the
  ## replay that is already serving. Skipped when the startup load failed so
  ## a later request can retry it.
  if not loaded:
    return
  let uri = getEnv(CogameLoadReplayUriEnv).strip()
  if uri.len == 0:
    return
  {.gcsafe.}:
    withLock appState.lock:
      appState.currentReplayUri = uri

proc replayRequestUriOrPending(request: Request): tuple[uri: string, loaded: bool] =
  ## Returns the websocket URI, falling back to the URI captured when serving
  ## /client/replay. Kubernetes service-proxy websocket upgrades do not
  ## preserve query params, so the preceding client HTML request is the durable
  ## place to capture the artifact URI.
  result.uri = request.replayRequestUri()
  {.gcsafe.}:
    withLock appState.lock:
      result.loaded = appState.replayLoaded
      if result.uri.len == 0:
        if appState.pendingReplayUri.len > 0:
          result.uri = appState.pendingReplayUri
        elif appState.loadingReplayUri.len > 0:
          result.uri = appState.loadingReplayUri
        else:
          result.uri = appState.currentReplayUri

proc seatTakeoverEnabled(): bool =
  ## Returns true when this config turns the freeplay takeover mode on.
  {.gcsafe.}:
    withLock appState.lock:
      result = appState.config.allowSeatTakeover

proc takeoverRejection*(
  config: GameConfig,
  seat: int,
  token: string,
  wantsDirectAim: bool,
  seatTaken: bool
): string =
  ## The whole admission gate for a human takeover connection: "" admits,
  ## anything else is the 403 text.
  ##
  ## A proc rather than a chain inside the route because this gate is the only
  ## thing standing between a league server and a client that asks it for play
  ## capabilities, and a gate that is not tested for DISCRIMINATION — admitting
  ## what it should and refusing what it should — is not a gate. Note the
  ## direct-aim arm REFUSES rather than downgrading: a client silently granted
  ## a lesser capability than it asked for would aim at one thing and shoot at
  ## another.
  if not config.allowSeatTakeover:
    return "Seat takeover is not enabled on this server."
  if wantsDirectAim and not config.allowDirectAim:
    return "Direct aim is not enabled on this server."
  if seat < 0 or seat >= MaxPlayers or seat >= config.slots.len:
    return "Seat takeover requires a configured slot."
  if config.slots[seat].token.len > 0 and token != config.slots[seat].token:
    return "Takeover token does not match seat " & $seat & "."
  # A pinned token that matched the line above IS proof of identity: this
  # connection holds the seat's own secret, so it is that seat's rightful
  # human reconnecting (a browser reload is the common case), not a
  # stranger trying to steal an occupied seat. Refusing it here behind a
  # stale/zombie holder -- whose cleanup is a once-per-tick affair the
  # reload's new socket can easily out-race (see evictSeatTakeover) -- is
  # exactly the resume-vs-fresh-join asymmetry that left a reloaded /play
  # tab stuck on the client's blind retry loop with a black arena in the
  # meantime. Only an UNTOKENED seat (no secret to check identity against)
  # keeps the old first-come-first-served exclusivity.
  if seatTaken and config.slots[seat].token.len == 0:
    return "Seat " & $seat & " is already being taken over."
  ""

proc directAimEnabled(): bool =
  ## Returns true when this config arms the human direct-aim channel.
  {.gcsafe.}:
    withLock appState.lock:
      result = appState.config.allowDirectAim

proc aimAssistEnabled(): bool =
  ## Returns true when this config arms freeplay aim assist.
  {.gcsafe.}:
    withLock appState.lock:
      result = appState.config.allowAimAssist

proc cosmeticFxEnabled(): bool =
  ## Returns true when this config arms the private cosmetic-effects channel
  ## (GameConfig.allowCosmeticFx) — the gate itself has worked since it
  ## shipped, this just reports it here too, same as the other three gates
  ## below.
  {.gcsafe.}:
    withLock appState.lock:
      result = appState.config.allowCosmeticFx

proc calloutsEnabled(): bool =
  ## Returns true when this config arms the callout channel.
  {.gcsafe.}:
    withLock appState.lock:
      result = appState.config.allowCallouts

proc capabilitiesJson(): string =
  ## What this server will GRANT a human connection. The same client bundle is
  ## served to league and play servers, so the client feature-DETECTS here
  ## rather than being built two ways. A league config advertises all of
  ## these as false, and asking anyway is refused at the upgrade (or, for aim
  ## assist/callouts/cosmetic fx, simply never applied) — advertising and
  ## enforcement read the same config fields, so they cannot drift. Every one
  ## of this config's armed gates is mirrored here, not just the two the
  ## shipped takeover.html shell happens to read today — a future consumer
  ## asking this endpoint about aim assist, callouts, or the cosmetic-fx/
  ## glory-toast channel gets a real answer instead of a silent `undefined`.
  $(%*{
    "seatTakeover": seatTakeoverEnabled(),
    "directAim": directAimEnabled(),
    "allowAimAssist": aimAssistEnabled(),
    "allowCallouts": calloutsEnabled(),
    "allowCosmeticFx": cosmeticFxEnabled()
  })

proc pickFreeplaySeat*(
  board: seq[SeatSnapshot],
  taken: seq[int],
  seatCount: int,
  preferAlive: bool = false
): tuple[seat, waitTicks: int] =
  ## Picks the seat a Free Play arrival should be handed, and says how long
  ## that arrival will stand around before it drives.
  ##
  ## THE SPEED RULE: prefer a cog that is already DOWN, soonest respawn first.
  ## The swap lands on the cog's next respawn, so handing someone a healthy cog
  ## makes them wait out a whole life for no reason, while a cog with 9 ticks
  ## left on its timer puts them on the field in under half a second. This is
  ## the difference between "click play and play" and "click play and wonder".
  ##
  ## A seat with no cog yet (between matches) is next best: the opening spawn
  ## lands every pending takeover at once. A healthy cog is the last resort,
  ## and its wait is unknowable from here -- reported as -1, never as a guess.
  ##
  ## `preferAlive` (brMode) INVERTS the speed rule: sim.nim's killPlayer
  ## forces lives=0/respawnTimer=0 on a brMode death, permanently -- a brMode
  ## cog reported "down" in a lives:1 game means eliminated for the rest of
  ## the round, not "back in a few ticks", and advanceSeatTakeover's `instant`
  ## branch only ever lands on a cog that is ALIVE on its first sampled frame.
  ## Applying the respawning-mode rule to brMode would confidently hand every
  ## arrival the ONE cog guaranteed to never come back until the next full
  ## reset -- measured before this fix as 7-15s+ mid-round joins climbing
  ## with roster size. So in brMode: alive is the near-zero wait (the instant
  ## branch fires next frame), down is the unknowable one.
  result = (-1, -1)
  var bestWait = int.high
  for entry in board:
    if entry.seat < 0 or entry.seat >= seatCount or entry.seat in taken:
      continue
    let wait =
      if preferAlive:
        (if entry.alive: 0 else: int.high - 1)
      elif entry.alive:
        int.high - 1        # ranked last, and its wait is not knowable here
      else:
        max(entry.respawnTimer, 0)
    if wait < bestWait:
      bestWait = wait
      result = (
        entry.seat,
        if preferAlive: (if entry.alive: 0 else: -1)
        else: (if entry.alive: -1 else: wait)
      )
  if result.seat >= 0:
    return
  # No roster yet (between matches, or before the policies have joined): any
  # configured seat that nobody holds will land at the opening whistle.
  for seat in 0 ..< seatCount:
    if seat notin taken:
      return (seat, 0)

proc freeplaySeatJson(): string =
  ## The one call an app makes to answer "which seat do I put this person in?".
  ## Returns the seat and the wait in ticks and milliseconds, so a surface can
  ## say "you are in in 0.4s" instead of an unbounded "suiting up...". A wait
  ## of -1 means the cog is healthy and the wait is genuinely not knowable --
  ## reported honestly rather than guessed.
  var
    board: seq[SeatSnapshot] = @[]
    taken: seq[int] = @[]
    seatCount = 0
    enabled = false
    brMode = false
  {.gcsafe.}:
    withLock appState.lock:
      enabled = appState.config.allowSeatTakeover
      if enabled:
        board = appState.seatBoard
        seatCount = appState.config.slots.len
        brMode = appState.config.brMode
        for _, takeover in appState.takeovers.pairs:
          taken.add(takeover.seat)
  if not enabled:
    return $(%*{"enabled": false, "seat": -1})
  let pick = pickFreeplaySeat(board, taken, seatCount, brMode)
  $(%*{
    "enabled": true,
    "directAim": directAimEnabled(),
    "seat": pick.seat,
    "waitTicks": pick.waitTicks,
    "waitMs":
      (if pick.waitTicks < 0: -1
       else: pick.waitTicks * 1000 div ReplayFps)
  })

proc takeoverStateLabel(takeover: SeatTakeover, brMode: bool): string =
  ## The status word a surface renders for one pending/driving takeover row.
  ##
  ## "driving": the swap has landed, this human is in the sim right now.
  ##
  ## "seated-awaiting-round" (brMode only): the request is bound to a seat
  ## whose cog is down RIGHT NOW in a mode where a down cog never respawns
  ## mid-round (sim.nim's killPlayer forces lives=0/respawnTimer=0 for the
  ## rest of the round in brMode) — so nothing sub-second is coming for this
  ## seat; the swap lands at the next spawn, which in brMode means the next
  ## round (landSeatTakeoversOnNewMatch). Distinct from "suiting-up" so a
  ## client can show honest "you're in next round" copy instead of implying
  ## an imminent respawn that is not going to happen.
  ##
  ## "suiting-up": every other pending case — a CTF cog mid-respawn-timer, a
  ## seat with no cog sampled yet, or a brMode cog that is ALIVE right now and
  ## about to land on literally the next frame (the `instant` path).
  if takeover.active:
    "driving"
  elif brMode and takeover.observed and not takeover.cogAlive:
    "seated-awaiting-round"
  else:
    "suiting-up"

proc takeoverStatusJson(): string =
  ## Returns the seat-takeover state a surface renders: who is on which seat
  ## and whether they are still suiting up. Ordered by seat so the strip does
  ## not reshuffle between polls.
  let enabled = seatTakeoverEnabled()
  var rows: seq[SeatTakeover] = @[]
  var brMode = false
  {.gcsafe.}:
    withLock appState.lock:
      brMode = appState.config.brMode
      for _, takeover in appState.takeovers.pairs:
        rows.add(takeover)
  rows.sort(proc (a, b: SeatTakeover): int = cmp(a.seat, b.seat))
  var seats = newJArray()
  for takeover in rows:
    seats.add(%*{
      "seat": takeover.seat,
      "requestedSeat": takeover.requestedSeat,
      "name": takeover.name,
      "state": takeover.takeoverStateLabel(brMode),
      "cog": takeover.cog,
      "cogAlive": takeover.cogAlive,
      "cogX": takeover.cogX,
      "cogY": takeover.cogY,
      "mask": int(takeover.lastMask),
      "policyMask": int(takeover.policyMask),
      "directAim": takeover.directAim,
      "aimBrads": takeover.aimBrads
    })
  $(%*{
    "enabled": enabled,
    "directAim": directAimEnabled(),
    "seats": seats
  })

proc httpHandler(request: Request) =
  # "/health" (no z) is not a route this server ever defined, but it is the
  # path tooling reaches for by reflex -- and until this fix it fell through
  # to the "CTF server" catch-all below, which answers 200 for literally any
  # unmatched path. That made a monitor curling /health indistinguishable
  # from one curling the real health check: both saw 200. Answered as a real
  # alias of HealthPath (same "healthy" body) rather than 404'd, because
  # something IS already polling it expecting 200 -- this makes that 200
  # true instead of refusing it outright.
  if request.path in [HealthPath, "/health"] and request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain; charset=utf-8"
    headers["Cache-Control"] = "no-cache"
    request.respond(200, headers, "healthy")
  elif request.path == CapabilitiesPath and request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "application/json; charset=utf-8"
    headers["Cache-Control"] = "no-cache"
    headers["Access-Control-Allow-Origin"] = "*"
    request.respond(200, headers, capabilitiesJson())
  elif request.path == TakeoverSeatPath and request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "application/json; charset=utf-8"
    headers["Cache-Control"] = "no-cache"
    headers["Access-Control-Allow-Origin"] = "*"
    request.respond(200, headers, freeplaySeatJson())
  elif request.path == TakeoverStatusPath and request.httpMethod == "GET":
    var headers: HttpHeaders
    headers["Content-Type"] = "application/json; charset=utf-8"
    headers["Cache-Control"] = "no-cache"
    headers["Access-Control-Allow-Origin"] = "*"
    request.respond(200, headers, takeoverStatusJson())
  elif request.path == TakeoverClientPath and request.httpMethod == "GET":
    if not seatTakeoverEnabled():
      request.respondForbiddenWebSocket(
        "Seat takeover is not enabled on this server."
      )
      return
    var headers: HttpHeaders
    headers["Content-Type"] = "text/html; charset=utf-8"
    headers["Cache-Control"] = "no-cache"
    request.respond(200, headers, EmbeddedTakeoverHtml)
  elif request.path == TakeoverWebSocketPath and request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    # A human asking to stand in for an occupied seat. The seat's token is the
    # takeover token: whoever the app hands the seat to may drive it.
    let
      seat = request.playerSlot()
      token = request.playerToken()
      requestedName =
        request.queryParams.getOrDefault("name", "").cleanGuestName()
      # Opt-in, and REFUSED rather than ignored when the config does not arm
      # it. A silent downgrade would let a client believe it is pointing while
      # the server is still swinging, and — worse — would let a league server
      # answer a play client at all.
      wantsDirectAim = request.queryParams.getOrDefault("directAim", "") in
        ["1", "true", "yes"]
    var reject = ""
    {.gcsafe.}:
      withLock appState.lock:
        reject = appState.config.takeoverRejection(
          seat, token, wantsDirectAim, seat.takeoverSeatTaken())
    if reject.len > 0:
      request.respondForbiddenWebSocket(reject)
      return
    let websocket = request.upgradeToWebSocket()
    var
      guestName = requestedName
      lost = false
    {.gcsafe.}:
      withLock appState.lock:
        # Re-checked under the lock: two upgrades can race between the
        # pre-upgrade check and here, and a seat takes exactly one human.
        #
        # `tokenProvesIdentity` mirrors takeoverRejection's own reasoning: a
        # non-empty, already-token-matched seat means THIS connection is
        # provably the seat's rightful holder (a reload is the common case),
        # so it supersedes whatever stale/zombie socket still holds the seat
        # (evictSeatTakeover) instead of queuing behind a cleanup pass that
        # only runs once per main-loop tick. An untokened seat has no secret
        # to check identity against, so it keeps the old exclusivity.
        let tokenProvesIdentity =
          seat >= 0 and seat < appState.config.slots.len and
          appState.config.slots[seat].token.len > 0
        if not appState.config.allowSeatTakeover or
            (seat.takeoverSeatTaken() and not tokenProvesIdentity):
          lost = true
        else:
          if seat.takeoverSeatTaken():
            evictSeatTakeover(seat)
          if guestName.len == 0:
            guestName = "Guest" & $(appState.takeovers.len + 1)
          websocket.registerTakeoverWebSocket(
            seat,
            guestName,
            wantsDirectAim and appState.config.allowDirectAim
          )
    if lost:
      websocket.disconnectWebSocket()
      return
    echo "seat takeover requested: ", guestName, " -> seat ", seat
  elif request.path == WebSocketPath and request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    let
      slot = request.playerSlot()
      token = request.playerToken()
      identity = request.playerIdentity(slot, token)
    var usePlaySeatTransport = false
    {.gcsafe.}:
      withLock appState.lock:
        let joinError = appState.config.configuredPlayerJoinError(
          identity,
          slot,
          token
        )
        if joinError.len > 0:
          request.respondForbiddenWebSocket(joinError)
          return
        usePlaySeatTransport =
          appState.config.playerUpgradeUsesPlaySeatTransport(slot)
    if identity.identityIsKicked():
      request.respondKicked()
      return
    let websocket =
      if usePlaySeatTransport:
        request.upgradePlaySeatWebSocket()
      else:
        request.upgradeToWebSocket()
    var
      accepted = false
      replacedPlaySocket = false
      oldPlaySocket: WebSocket
    {.gcsafe.}:
      withLock appState.lock:
        accepted = websocket.registerPlayerWebSocket(
          identity, slot, token, replacedPlaySocket, oldPlaySocket)
    if not accepted:
      websocket.disconnectWebSocket()
      return
    if replacedPlaySocket:
      oldPlaySocket.disconnectWebSocket()
    echo "player connected: ", identity
  elif request.path == GlobalWebSocketPath and request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    if request.hasPlayerCredentialParams():
      request.respondForbiddenViewer()
      return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        websocket.registerGlobalWebSocket()
  elif request.path == ReplayWebSocketPath and request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    if request.hasPlayerCredentialParams():
      request.respondForbiddenViewer()
      return
    let replayServerMode = replayServerModeEnabled()
    let replayRequest =
      if replayServerMode:
        request.replayRequestUriOrPending()
      else:
        (uri: "", loaded: false)
    if replayServerMode:
      if replayRequest.uri.len == 0 and not replayRequest.loaded:
        request.respondReplayRequestError(400, "missing replay uri\n")
        return
      if replayRequest.uri.len > 0 and
          not replayRequest.uri.replayUriKnown() and
          not replayRequest.uri.readableReplayUri():
        request.respondReplayRequestError(404, "replay uri is not readable\n")
        return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        websocket.registerGlobalWebSocket()
        if replayServerMode and replayRequest.uri.len > 0 and
            replayRequest.uri != appState.pendingReplayUri and
            replayRequest.uri != appState.loadingReplayUri and
            replayRequest.uri != appState.currentReplayUri:
          appState.pendingReplayUri = replayRequest.uri
  elif request.path == AdminWebSocketPath and request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    if request.hasPlayerCredentialParams():
      request.respondForbiddenViewer()
      return
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        websocket.registerGlobalWebSocket()
  elif request.path == RewardWebSocketPath and request.httpMethod == "GET" and
      request.isWebSocketUpgrade():
    let websocket = request.upgradeToWebSocket()
    {.gcsafe.}:
      withLock appState.lock:
        websocket.registerRewardWebSocket()
  elif (request.path == ControlRestartPath or request.path == ControlKickPath) and
      request.httpMethod == "OPTIONS":
    request.respondControl(204, "")
  elif request.path == ControlRestartPath and request.httpMethod == "POST":
    if replayControlsDisabled():
      request.respondControl(409, "match controls are disabled for replays\n")
    else:
      {.gcsafe.}:
        withLock appState.lock:
          appState.resetRequested = true
      request.respondControl(202, "restart queued\n")
  elif request.path == ControlKickPath and request.httpMethod == "POST":
    if replayControlsDisabled():
      request.respondControl(409, "match controls are disabled for replays\n")
    else:
      let identity = request.queryParams.getOrDefault(
        "identity",
        ""
      ).cleanPlayerName()
      if identity.len == 0:
        request.respondControl(400, "missing identity\n")
      else:
        {.gcsafe.}:
          withLock appState.lock:
            appState.kickRequests.add(identity)
        request.respondControl(202, "kick queued\n")
  elif request.path in [WallTextureHorizontalPath, WallTextureVerticalPath] and
      request.httpMethod == "GET":
    # Dungeon-wall textures for the League Replayer shell (static JPEG assets).
    var texHeaders: HttpHeaders
    texHeaders["Content-Type"] = "image/jpeg"
    texHeaders["Cache-Control"] = "public, max-age=3600"
    if request.path == WallTextureHorizontalPath:
      request.respond(200, texHeaders, WallTextureHorizontal)
    else:
      request.respond(200, texHeaders, WallTextureVertical)
  elif request.httpMethod == "GET" and (block:
      var lockerHit = false
      for (path, art) in LockerRoomAssets:
        if request.path == path:
          lockerHit = true
          break
      lockerHit):
    # The broadcast client's locker-room loading-scene assets: the JPEG
    # room plate and the per-cog alpha-sprite poses (WebP).
    var lockerHeaders: HttpHeaders
    lockerHeaders["Content-Type"] =
      if request.path.endsWith(".webp"): "image/webp"
      else: "image/jpeg"
    lockerHeaders["Cache-Control"] = "public, max-age=3600"
    for (path, art) in LockerRoomAssets:
      if request.path == path:
        request.respond(200, lockerHeaders, art)
        break
  elif request.httpMethod == "GET" and (block:
      var hit = false
      for (path, art) in SoldierArtAssets:
        if request.path == path:
          hit = true
          break
      hit):
    # Cog art for the EYES PiP billboards (static PNG assets): the _front
    # eye-level masters the billboard blits (with and without the gun); a
    # missing master falls back to the procedural chassis client-side.
    var artHeaders: HttpHeaders
    artHeaders["Content-Type"] = "image/png"
    artHeaders["Cache-Control"] = "public, max-age=3600"
    for (path, art) in SoldierArtAssets:
      if request.path == path:
        request.respond(200, artHeaders, art)
        break
  elif request.path == BroadcastFontPath and request.httpMethod == "GET":
    var fontHeaders: HttpHeaders
    fontHeaders["Content-Type"] = "font/ttf"
    fontHeaders["Cache-Control"] = "public, max-age=3600"
    request.respond(200, fontHeaders, BroadcastFont)
  elif request.path in [
      bitworldClient.ReplayClientRoute,
      bitworldClient.CoworldReplayClientRoute,
      LeagueReplayerPath
    ] and request.httpMethod == "GET":
    if replayServerModeEnabled():
      let replayRequest = request.replayRequestUriOrPending()
      if replayRequest.uri.len == 0 and not replayRequest.loaded:
        request.respondReplayRequestError(400, "missing replay uri\n")
        return
      if replayRequest.uri.len > 0 and
          not replayRequest.uri.replayUriKnown() and
          not replayRequest.uri.readableReplayUri():
        request.respondReplayRequestError(404, "replay uri is not readable\n")
        return
      if replayRequest.uri.len > 0:
        replayRequest.uri.queueReplayUri()
    # The regular replay routes serve the plain designed broadcast client (the
    # board) exactly as before. /client/league is an ADD-ON that serves the
    # walled-pit League Replayer SHELL, which itself embeds the board in an
    # iframe at /client/replay?embed=1 — the board client reads ?embed=1 to hide
    # its own chrome so the shell owns the walls/scorebug/rosters. One websocket,
    # perfect tick sync. (ELEVATE-BY-REBUILD: our HTML, not bitworld's.)
    var replayHeaders: HttpHeaders
    replayHeaders["Content-Type"] = "text/html; charset=utf-8"
    replayHeaders["Cache-Control"] = "no-cache"
    if request.path == LeagueReplayerPath:
      request.respond(200, replayHeaders, EmbeddedLeagueReplayerHtml)
    else:
      request.respond(200, replayHeaders, EmbeddedBroadcastReplayHtml)
  elif request.path in [
      bitworldClient.PlayerClientRoute,
      bitworldClient.PlayerClientHtmlRoute
    ] and request.httpMethod == "GET":
    # Season 2 human seat: ours wins because this branch sits AHEAD of the
    # bitworld fallback below, which would otherwise serve the generic
    # global/spectator client at this same path.
    var playerHeaders: HttpHeaders
    playerHeaders["Content-Type"] = "text/html; charset=utf-8"
    playerHeaders["Cache-Control"] = "no-cache"
    request.respond(200, playerHeaders, EmbeddedPlayerClientHtml)
  elif request.path in [
      bitworldClient.GlobalClientRoute,
      bitworldClient.CoworldGlobalClientRoute
    ] and request.httpMethod == "GET":
    # LIVE spectator chrome (proof stakes #7/#9): this used to fall straight
    # through to bitworld's bare "Global Viewer" below — a canvas with no
    # teams-alive strip, no endcard, no BR identity, while /client/replay's
    # rich broadcast chrome sat unreachable until AFTER a match was recorded
    # and reloaded as a file. That rich chrome is driven entirely by the
    # global-viewer sprite-protocol stream (ensured by /replay ALSO calling
    # registerGlobalWebSocket() when this process is not a dedicated replay
    # server — see the ReplayWebSocketPath branch below), so a live match and
    # a loaded replay already speak the identical wire protocol to this same
    # HTML; the only thing missing was the route. broadcast_core.js's
    # websocketPathForClientPage() points THIS path's socket at plain /global
    # (GlobalWebSocketPath) rather than /replay, on purpose: the live route
    # must never carry replay-server uri-load semantics, even if this process
    # happens to be configured as one.
    var globalHeaders: HttpHeaders
    globalHeaders["Content-Type"] = "text/html; charset=utf-8"
    globalHeaders["Cache-Control"] = "no-cache"
    request.respond(200, globalHeaders, EmbeddedBroadcastReplayHtml)
  elif request.path == ReplayPlusPovClientPath and request.httpMethod == "GET":
    # Hosted-replay half of global_plus_pov: the same uri-load contract as
    # the plain /client/replay branch above (queueReplayUri / 400-missing /
    # 404-unreadable), because broadcast_core.js's websocketPathForClientPage
    # points THIS route's sockets at /replay too — both the board connection
    # and the POV-inset connection the page opens need the replay actually
    # queued before either can answer.
    if replayServerModeEnabled():
      let replayRequest = request.replayRequestUriOrPending()
      if replayRequest.uri.len == 0 and not replayRequest.loaded:
        request.respondReplayRequestError(400, "missing replay uri\n")
        return
      if replayRequest.uri.len > 0 and
          not replayRequest.uri.replayUriKnown() and
          not replayRequest.uri.readableReplayUri():
        request.respondReplayRequestError(404, "replay uri is not readable\n")
        return
      if replayRequest.uri.len > 0:
        replayRequest.uri.queueReplayUri()
    var replayPlusPovHeaders: HttpHeaders
    replayPlusPovHeaders["Content-Type"] = "text/html; charset=utf-8"
    replayPlusPovHeaders["Cache-Control"] = "no-cache"
    request.respond(200, replayPlusPovHeaders, EmbeddedGlobalPlusPovHtml)
  elif request.path == GlobalPlusPovClientPath and request.httpMethod == "GET":
    # Live half of global_plus_pov: same treatment as the /client/global
    # branch above — no uri handling, socket points at plain /global
    # (GlobalWebSocketPath), never the replay-uri-load path, even on a
    # process configured as a replay server.
    var globalPlusPovHeaders: HttpHeaders
    globalPlusPovHeaders["Content-Type"] = "text/html; charset=utf-8"
    globalPlusPovHeaders["Cache-Control"] = "no-cache"
    request.respond(200, globalPlusPovHeaders, EmbeddedGlobalPlusPovHtml)
  elif bitworldClient.serveClientRoute(
    request,
    bitworldClient.GlobalClientRoute
  ):
    discard
  elif request.path.startsWith("/client/"):
    # An unmatched /client/* path is, by construction, a missing static
    # asset -- e.g. a direct GET to /client/player_hud.js, which names a
    # real file in this repo's client/ dir but is never served at that URL
    # (its content only ever reaches the browser inlined into /client/player
    # -- see the long comment on EmbeddedPlayerClientHtml above). The blanket
    # "CTF server" fallback below returns 200 for that case, which is
    # precisely the failure class that hid this project's worst client bug
    # twice: a status/byte-count check sees a healthy-looking 200 while the
    # body is either ten bytes of plain text a <script> tag would try to
    # execute and die on, or (the prior, worse case) a fully-formed HTML
    # page for the WRONG route. Scoped to the /client/ namespace only --
    # nothing here changes the response for any other unmatched path (root,
    # health probes, etc.), since this lane has no visibility into what
    # external tooling may depend on that behaviour.
    var notFoundHeaders: HttpHeaders
    notFoundHeaders["Content-Type"] = "text/plain"
    request.respond(404, notFoundHeaders, "not found\n")
  elif request.path notin [
      HealthPath, "/health", AdminWebSocketPath, TakeoverWebSocketPath,
      TakeoverStatusPath, TakeoverSeatPath, CapabilitiesPath,
      ControlRestartPath, ControlKickPath, WebSocketPath, GlobalWebSocketPath,
      ReplayWebSocketPath, RewardWebSocketPath
    ]:
    # Same failure class as the /client/* branch above, extended to the rest
    # of the surface: a path outside /client/ that is not one of this
    # server's own top-level routes is, by construction, not a route at all
    # -- e.g. /status or a typo'd /health (before the alias above), both
    # measured live returning 200 "CTF server" and indistinguishable from a
    # real check without reading the body. Investigated before narrowing
    # this: neither the pbnf tooling (pbnf-swap/-route/-deploy all assert on
    # /_app/health, /capabilities, or /api/field content -- never a bare
    # unmatched path) nor the Node proxy in front of this process (app.mjs's
    # own routes own everything under /api/ /lobby/ /match/ /assets/ /_app/
    # and the exact page set; matchd.mjs's readiness probe is a raw TCP
    # connect, no path at all) depends on an unrecognized top-level path
    # answering 200. A path that IS one of ours but got the wrong method or
    # missing upgrade headers still falls to the 200 branch below, unchanged
    # -- this only narrows the "not a route we have at all" case.
    var topLevelNotFoundHeaders: HttpHeaders
    topLevelNotFoundHeaders["Content-Type"] = "text/plain"
    request.respond(404, topLevelNotFoundHeaders, "not found\n")
  else:
    var headers: HttpHeaders
    headers["Content-Type"] = "text/plain"
    request.respond(200, headers, "CTF server")

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) =
  case event
  of OpenEvent:
    var closeKickedSocket = false
    {.gcsafe.}:
      withLock appState.lock:
        if websocket in appState.globalViewers or
            websocket in appState.rewardViewers:
          discard removePlayerWebSocketState(websocket)
        elif websocket.isPlayerWebSocket():
          let address = appState.playerAddresses.getOrDefault(websocket, "")
          if address.addressIsKicked():
            discard removePlayerWebSocketState(websocket)
            closeKickedSocket = true
          elif websocket notin appState.playerIndices:
            appState.playerIndices[websocket] =
              if appState.replayLoaded:
                -1
              else:
                UnresolvedPlayerIndex
            appState.inputMasks[websocket] = 0
            appState.inputPressedMasks[websocket] = 0
            appState.lastAppliedMasks[websocket] = 0
            appState.playerReady[websocket] = false
    if closeKickedSocket:
      websocket.disconnectWebSocket()
  of MessageEvent:
    if message.kind == Ping:
      websocket.send(message.data, Pong)
    elif message.kind == BinaryMessage:
      var disconnectPlaySocket = false
      {.gcsafe.}:
        withLock appState.lock:
          let playSeat = websocket.playSeatIndex()
          if playSeat >= 0 and websocket in appState.playerViewers and
              not appState.replayLoaded:
            disconnectPlaySocket = not websocket.dispatchPlaySeatMessage(
              playSeat, message.data)
          elif message.data.isPlayerReadyPacket() and
              websocket in appState.playerReady:
            appState.playerReady[websocket] = true
          elif message.data.isSpritesOffPacket():
            appState.spritesOff[websocket] = true
          elif websocket in appState.globalViewers:
            appState.globalViewers[websocket].applyGlobalViewerMessage(
              message.data
            )
          elif websocket in appState.playerViewers and
              not appState.replayLoaded:
            websocket.applyPlayerSpriteMessage(message.data)
      if disconnectPlaySocket:
        websocket.disconnectWebSocket()
  of ErrorEvent, CloseEvent:
    var who = ""
    {.gcsafe.}:
      withLock appState.lock:
        let newlyClosed = markSocketClosed(websocket)
        let playSeat = websocket.playSeatIndex()
        if newlyClosed and playSeat >= 0:
          let ingressSeat = playSeat.playIngressSeat()
          if ingressSeat != nil:
            discard ingressSeat[].binding.lose(websocket)
            if playSeat < appState.playOutbound.len:
              appState.playOutbound[playSeat].loseOutbound(websocket)
        if newlyClosed and websocket in appState.playerAddresses:
          who = appState.playerAddresses[websocket]
    if who.len > 0:
      echo "player disconnected: ", who

proc serverThreadProc(args: ServerThreadArgs) {.thread.} =
  args.server[].serve(Port(args.port), args.address)

proc resetPlayerReady(
  sockets: openArray[WebSocket],
  playerIndices: openArray[int],
  playerCount: int
) =
  ## Clears readiness for active player sockets before sending one frame.
  {.gcsafe.}:
    withLock appState.lock:
      for i, websocket in sockets:
        if i < playerIndices.len and playerIndices[i] >= 0 and
            playerIndices[i] < playerCount and
            websocket in appState.playerReady:
          appState.playerReady[websocket] = false
    if muxState.enabled:
      withLock muxState.lock:
        for slot in 0 ..< MaxMuxSeats:
          if muxState.seats[slot].joined and
              muxState.seats[slot].playerIndex >= 0 and
              muxState.seats[slot].playerIndex < playerCount:
            muxState.seats[slot].ready = false

proc allPlayersReady(
  sockets: openArray[WebSocket],
  playerIndices: openArray[int],
  playerCount: int
): bool =
  ## Returns true when every active player (socket or mux seat) sent ready.
  var activePlayers = 0
  {.gcsafe.}:
    withLock appState.lock:
      for i, websocket in sockets:
        if i >= playerIndices.len or playerIndices[i] < 0 or
            playerIndices[i] >= playerCount:
          continue
        inc activePlayers
        if not appState.playerReady.getOrDefault(websocket, false):
          return false
    if muxState.enabled:
      withLock muxState.lock:
        for slot in 0 ..< MaxMuxSeats:
          if muxState.seats[slot].joined and
              muxState.seats[slot].playerIndex >= 0 and
              muxState.seats[slot].playerIndex < playerCount:
            inc activePlayers
            if not muxState.seats[slot].ready:
              return false
  activePlayers > 0

type
  FrameAdvance = enum
    LateFrame,    ## the frame budget was already spent before the limiter ran
    SkippedFrame, ## fastMode: every player reported ready before the budget
    WaitedFrame   ## slept out the remaining wall-clock frame budget

  PlayerTraffic = object
    bytesTotal, bytesImage, bytesObject, bytesOther: int64

  ServerMetrics = object
    frames: array[FrameAdvance, int]
    players: seq[PlayerTraffic]
    ## Object-update bytes bucketed by BoardObjectPools pool name; ids
    ## outside every pool (map, flags, players, HUD) land in "core".
    objectPools: Table[string, int64]

  ShellTimingWindow = object
    stageNanoseconds: array[ShellStage, int64]
    maxTickNanoseconds: int64
    simNanoseconds: int64
    ticks: int

proc addShellTiming(window: var ShellTimingWindow,
                         tick: ShellTickResult) =
  if tick.masks.len == 0:
    return
  for stage in ShellStage:
    window.stageNanoseconds[stage] += tick.stageNanoseconds[stage]
  window.maxTickNanoseconds = max(
    window.maxTickNanoseconds, tick.stageNanoseconds.shellNanoseconds)
  inc window.ticks

proc finishShellTimingTick(window: var ShellTimingWindow,
                                tick: uint32, seats: int,
                                simNanoseconds: int64): string =
  if seats > 0:
    window.simNanoseconds += simNanoseconds
  if tick mod uint32(TargetFps) != 0:
    return
  if seats > 0:
    result = formatTimingSummary(tick, seats, window.ticks,
      window.stageNanoseconds, window.maxTickNanoseconds,
      window.simNanoseconds)
  window = ShellTimingWindow()

proc runFrameLimiter(
  previousTick: var MonoTime,
  fastMode: bool,
  sockets: openArray[WebSocket],
  playerIndices: openArray[int],
  playerCount: int
): FrameAdvance =
  let frameDuration = initDuration(microseconds = 1_000_000 div TargetFps)
  var slept = false
  while true:
    let elapsed = getMonoTime() - previousTick
    if elapsed >= frameDuration:
      result = if slept: WaitedFrame else: LateFrame
      break
    if fastMode and sockets.allPlayersReady(playerIndices, playerCount):
      result = SkippedFrame
      break
    let remaining = frameDuration - elapsed
    sleep(max(1, min(2, int(remaining.inMilliseconds))))
    slept = true
  previousTick = getMonoTime()

proc recordTraffic(
  metrics: var ServerMetrics,
  playerIndex: int,
  packet: openArray[uint8]
) =
  ## Tallies one outgoing player packet, split by sprite-protocol message
  ## type: sprite definitions carry pixel maps, board objects carry the
  ## per-tick state; viewport/layer chrome counts as other.
  if playerIndex < 0 or playerIndex >= MaxPlayers or packet.len == 0:
    return
  if playerIndex >= metrics.players.len:
    metrics.players.setLen(playerIndex + 1)
  metrics.players[playerIndex].bytesTotal += packet.len.int64
  var offset = 0
  while offset < packet.len:
    let messageStart = offset
    let messageType = packet[offset]
    inc offset
    case messageType
    of 0x01:  # sprite: id,w,h (6) + clen (4) + pixels + llen (2) + label
      let compressedLen = packet.packetU32(offset + 6)
      offset += 10 + compressedLen
      let labelLen = packet.packetU16(offset)
      offset += 2 + labelLen
      metrics.players[playerIndex].bytesImage += int64(offset - messageStart)
    of 0x02, 0x03, 0x04:
      if messageType != 0x04:
        let objectId = packet.packetU16(offset)
        metrics.objectPools.mgetOrPut(boardObjectPoolName(objectId), 0) +=
          int64(if messageType == 0x02: 12 else: 3)
      offset += (if messageType == 0x02: 11 elif messageType == 0x03: 2 else: 0)
      metrics.players[playerIndex].bytesObject += int64(offset - messageStart)
    of 0x05, 0x06:
      offset += (if messageType == 0x05: 5 else: 3)
      metrics.players[playerIndex].bytesOther += int64(offset - messageStart)
    else:
      # Unknown message: its size is unknowable, so attribute the remainder
      # and stop — mirrors chunkSpritePacket's bail-out.
      metrics.players[playerIndex].bytesOther += int64(packet.len - messageStart)
      break

proc metricsJson(metrics: ServerMetrics, sim: SimServer, ticks: int): string =
  ## Serializes the performance counters recorded over one server run.
  var players = newJArray()
  for i in 0 ..< metrics.players.len:
    let traffic = metrics.players[i]
    players.add(%*{
      "slot": i,
      "name": if i < sim.players.len: sim.players[i].address else: "",
      "bytesTotal": traffic.bytesTotal,
      "bytesImage": traffic.bytesImage,
      "bytesObject": traffic.bytesObject,
      "bytesOther": traffic.bytesOther
    })
  var objectPools = newJObject()
  for name, bytes in metrics.objectPools:
    objectPools[name] = %bytes
  $(%*{
    "ticks": ticks,
    "frames": {
      "skipped": metrics.frames[SkippedFrame],
      "waited": metrics.frames[WaitedFrame],
      "late": metrics.frames[LateFrame],
      "total": metrics.frames[SkippedFrame] + metrics.frames[WaitedFrame] +
        metrics.frames[LateFrame]
    },
    "objectPools": objectPools,
    "players": players
  })

proc rewardAccountFor(sim: SimServer, address: string): int =
  ## Returns the reward account index for one address.
  for i in 0 ..< sim.rewardAccounts.len:
    if sim.rewardAccounts[i].address == address:
      return i
  -1

proc writeInputFrameMasks(
  replayWriter: var CtfReplayWriter,
  time: uint32,
  playerIndex: int,
  appliedMask,
  pressedMask: uint8
) =
  ## Writes replay input changes for one sampled player frame.
  if playerIndex < 0 or playerIndex >= replayWriter.lastMasks.len:
    return
  let repeatedPressedMask = pressedMask and replayWriter.lastMasks[playerIndex]
  if repeatedPressedMask != 0:
    replayWriter.writeInputMaskChange(
      time,
      playerIndex,
      replayWriter.lastMasks[playerIndex] and not repeatedPressedMask
    )
  replayWriter.writeInputMaskChange(time, playerIndex, appliedMask)

proc drainPlayerDebugSprites*(
  state: PlayerViewerState,
  time: uint32,
  playerIndex: int,
  replayWriter: var CtfReplayWriter,
  overlay: var DebugOverlay
) =
  ## Drains, caps, records, and folds one player's pending debug packets.
  let packets = state.pendingDebugSprites
  state.pendingDebugSprites = @[]
  var usedBytes = 0
  for packet in packets:
    if packet.len > MaxDebugSpriteBytesPerTick - usedBytes:
      if not state.debugSpriteLimitWarned:
        echo "debug sprite byte limit exceeded for player ", playerIndex
        state.debugSpriteLimitWarned = true
      continue
    usedBytes += packet.len
    try:
      packet.validateDebugSpritePacket()
      overlay.applyDebugSpritePacket(packet)
    except SpriteProtocolError, SnappyError:
      continue
    replayWriter.writeDebugSprite(time, playerIndex, packet)

proc clearPressedInputMask(input: var InputState, mask: uint8) =
  ## Clears previous input bits that were pressed this frame.
  if (mask and ButtonUp) != 0:
    input.up = false
  if (mask and ButtonDown) != 0:
    input.down = false
  if (mask and ButtonLeft) != 0:
    input.left = false
  if (mask and ButtonRight) != 0:
    input.right = false
  if (mask and ButtonSelect) != 0:
    input.select = false
  if (mask and ButtonA) != 0:
    input.attack = false
  if (mask and ButtonB) != 0:
    input.b = false
  if (mask and ButtonC) != 0:
    input.c = false

proc clearPressedInputMasks(
  inputs: var seq[InputState],
  masks: openArray[uint8]
) =
  ## Clears previous input bits for each per-frame pressed mask.
  for playerIndex, mask in masks:
    if playerIndex < inputs.len:
      inputs[playerIndex].clearPressedInputMask(mask)

proc resetInputMasks(masks: var seq[uint8]) =
  ## Clears all per-frame pressed masks.
  for mask in masks.mitems:
    mask = 0

proc addStatLine(
  packet: var string,
  name, identity: string,
  value: int
) =
  ## Appends one metric line to a reward protocol packet.
  packet.add(name)
  packet.add(' ')
  packet.add(identity)
  packet.add(' ')
  packet.add($value)
  packet.add('\n')

proc buildRewardPacket(sim: SimServer): string {.measure.} =
  ## Builds one reward protocol packet for the current tick.
  for player in sim.players:
    let
      identity = player.address.rewardAddress()
      accountIndex = sim.rewardAccountFor(player.address)
    result.addStatLine("reward", identity, player.reward)
    if accountIndex >= 0:
      let account = sim.rewardAccounts[accountIndex]
      # One wins/games line per ACTIVE team: 2-team games emit exactly the
      # classic wins_red..games_blue quartet, 4-team games add green/yellow.
      for team in sim.teams():
        result.addStatLine("wins_" & teamText(team), identity,
          account.wins[team])
      for team in sim.teams():
        result.addStatLine("games_" & teamText(team), identity,
          account.games[team])
      result.addStatLine("kills", identity, account.kills)
      result.addStatLine("team_kills", identity, account.teamKills)
      result.addStatLine("hit_damage", identity, account.hitDamage)
      result.addStatLine("team_hit_damage", identity, account.teamHitDamage)
      result.addStatLine("deaths", identity, account.deaths)
      result.addStatLine("captures", identity, account.captures)

proc buildShotFeedbackPacket(
  sim: SimServer,
  feedback: seq[ShotFeedbackFx],
  cog: int
): string {.measure.} =
  ## Builds the PRIVATE combat-outcome JSON for one takeover socket's cog
  ## this tick (GameConfig.allowShotFeedback), from whichever entries in
  ## `feedback` name `cog` as shooter or victim — the caller (this proc's one
  ## call site, the takeover send pass below) has already filtered `feedback`
  ## down to entries touching this cog at all, so every entry here matches at
  ## least one of the two branches below.
  ##
  ## Deliberately built here as a plain JSON string, sent as its own
  ## TextMessage — NOT folded into global.nim's sprite/label wire, which is
  ## shared with every policy socket. Returns "" when neither array would
  ## have anything in it, so the caller can skip the send outright.
  ##
  ## Delivered UNFOGGED: no fovVisibleAt check gates victimTeam/victimColor/
  ## killerTeam/killerColor here. See ShotFeedbackFx's doc comment for why —
  ## a direct participant in a combat event is entitled to its outcome
  ## regardless of their own fog at the moment it resolved. This proc never
  ## runs for any other seat, so that exception stays exactly as narrow as
  ## the two participants of each individual event.
  var shotsLanded = newJArray()
  var hitsTaken = newJArray()
  for fx in feedback:
    if fx.shooterIndex == cog and fx.targetIndex >= 0 and
        fx.targetIndex < sim.players.len:
      let victim = sim.players[fx.targetIndex]
      shotsLanded.add(%*{
        "kill": fx.kill,
        "friendlyFire": fx.friendlyFire,
        "weapon": fx.weapon,
        "distance": fx.distance,
        "victimTeam": teamText(victim.team),
        "victimColor": playerColorText(victim.color)
      })
    if fx.targetIndex == cog and fx.shooterIndex >= 0 and
        fx.shooterIndex < sim.players.len:
      let killer = sim.players[fx.shooterIndex]
      var taken = %*{
        "kill": fx.kill,
        "friendlyFire": fx.friendlyFire,
        "weapon": fx.weapon,
        "distance": fx.distance,
        "killerTeam": teamText(killer.team),
        "killerColor": playerColorText(killer.color)
      }
      if fx.kill:
        # Killcam: the killer's position, on the FATAL record ONLY — so the
        # victim's client can point a camera at who got them. A per-hit
        # shooter position would be a live wallhack for a still-standing
        # victim; a dead one cannot move or shoot, so revealing where their
        # killer stood at the death moment is the same narrow, principled
        # fog exception as the unfogged identity fields above and the
        # own-death pop (ShotFeedbackFx's doc comment) — scoped to the one
        # participant the round is already over for. shooterX/shooterY are
        # the impact-moment center captured at the populate site
        # (sim_types.nim); killerAlive is read HERE, at delivery on the
        # death tick, so a mutual trade correctly points the camera at a
        # corpse. Non-fatal entries are byte-identical to before this field
        # existed (nothing is appended), and the gate-off wire is untouched
        # (no record is ever populated).
        taken["killerX"] = %fx.shooterX
        taken["killerY"] = %fx.shooterY
        taken["killerAlive"] = %killer.alive
      hitsTaken.add(taken)
  if shotsLanded.len == 0 and hitsTaken.len == 0:
    return ""
  $(%*{"shotsLanded": shotsLanded, "hitsTaken": hitsTaken})

const CosmeticFxShotSamples = 14
  ## Points sampled along one in-flight shot's beam for the cosmetic-fx
  ## channel below — the same count broadcast.nim's firstPersonJson uses for
  ## the PiP's tracer polyline, kept in step even though this channel draws
  ## top-down (raw world xy) instead of the PiP's projected bearing/range.

proc buildCosmeticFxPacket(
  sim: SimServer,
  viewerIndex: int,
  gloryDeeds: seq[GloryDeedFx] = @[]
): string {.measure.} =
  ## Builds the fog-clipped cosmetic-effects JSON for one takeover socket's
  ## cog this tick (GameConfig.allowCosmeticFx): the two effects
  ## global.nim's addShotTracers/addPaintStains draw for the spectator/
  ## broadcast board only — paint tracers and permanent ground stains —
  ## rebuilt here straight from sim.recentShots/sim.paintStains and
  ## fog-clipped to `viewerIndex` with the same sim.fovVisibleAt check those
  ## two procs (and addSplatters' player path) already use. `gloryDeeds` is
  ## the third source: a frame-scoped seq the caller has already drained
  ## from sim.gloryDeeds (see the takeover send pass below), not sim state
  ## read directly like the two above — it is a one-shot queue like
  ## shotFeedback, not a fading/aged Fx seq, so it cannot be reread here
  ## after the frame that minted it. Defaulted to `@[]` so every existing
  ## call site (including every test in test_cosmetic_fx_wire.nim) keeps
  ## compiling unchanged.
  ##
  ## Deliberately a SEPARATE JSON TextMessage, like buildShotFeedbackPacket
  ## beside it — NOT folded into global.nim's sprite/label wire, which is
  ## shared with every policy/mux socket. That is what makes this channel
  ## safe BY CONSTRUCTION rather than by filtering: this proc has exactly
  ## one caller (the takeover send pass below), so a policy's own connection
  ## for this exact seat is simply never a target of the call, regardless of
  ## the gate — see GameConfig.allowCosmeticFx's own doc comment. Returns ""
  ## when nothing survives the fog clip, so the caller can skip the send.
  ##
  ## Wire shape — one effect FAMILY, `kind`-tagged so a member added later
  ## is an additive new object in the same array, never a new message type:
  ##   {"fx": [
  ##     {"kind":"tracer", "pts":[[x,y]|null, ...], "age":int,
  ##      "color":string, "hit":bool},
  ##     {"kind":"stain", "x":int, "y":int, "color":string, "onWall":bool},
  ##     {"kind":"glory", "tick":int, "word":string, "amount":int,
  ##      "team":string, "self":bool, "x":int, "y":int},
  ##     ...
  ##   ]}
  ## A tracer's `pts` walks muzzle -> impact; a sample this seat's fog does
  ## not currently cover is `null` rather than omitted, so the client BREAKS
  ## the line there instead of drawing a straight shot through fog — the
  ## same contract broadcast.nim's firstPersonJson already uses for the PiP
  ## inset. `color` is the same word playerColorText already gives
  ## buildShotFeedbackPacket's victimColor/killerColor, so the client's
  ## existing colorWordCss() palette lookup (player_client.html) applies
  ## unchanged.
  ##
  ## The "glory" kind (GloryDeedFx, RE-POINTED onto GV48's `awardDeed`
  ## ("THE SINGLE MINT", sim.nim) via its `fxActor` parameter — see
  ## GloryDeedFx's own doc comment for the swap9-era delta this replaced):
  ## fog-clipped by a SINGLE fovVisibleAt point check at the deed's actor
  ## position, the same single-point discipline `stain` above uses — not
  ## the multi-sample beam `tracer` walks, since a deed happens at one
  ## place, not along a path. A deed whose actorIndex is out of range is
  ## skipped outright (fail closed): there is no positionless fallback
  ## here, and there should never need to be one — both current mint sites
  ## (the kill-deed award in `killPlayer`, `dCapture` in
  ## `checkWinCondition`) have a real actor in hand, and any future one that
  ## genuinely lacks one should not emit at all rather than guess a point a
  ## fog check can't honestly clear. `team` below is `deed.team` — captured
  ## at MINT time by the same populate-time-facts rule every field here
  ## follows, never re-read from sim.players[deed.actorIndex] at build/send
  ## time (that seat could in principle no longer mean the same thing by the
  ## time this drains, even though today's same-tick drain makes it moot in
  ## practice — see GloryDeedFx.team's own doc comment).
  ##
  ## `self` answers the seat-vs-duo question AT THE WIRE: `awardDeed`'s
  ## `fxActor` caller already knows the specific crediting SEAT (a
  ## sim.players[] index, not a team-level identity — see GloryDeedFx.
  ## actorIndex's own doc comment), so this could have shipped seat-grain.
  ## It ships as a derived boolean instead (`self` = actorIndex == viewerIndex)
  ## plus `team`, never the raw actorIndex or an address: a duo's two seats
  ## already share one `color` by default in this config (roster.nim's
  ## addPlayer: `color = teamColor(team)` unless a slot pins its own), so
  ## `color`/`team` alone would read as "your DUO scored" even for your own
  ## kill — `self` is what lets the display layer say "YOU scored" instead,
  ## without this channel ever putting a bare seat index on the wire.
  if not sim.config.allowCosmeticFx:
    return ""
  if viewerIndex < 0 or viewerIndex >= sim.players.len:
    return ""
  var fx = newJArray()
  for shot in sim.recentShots:
    let
      sx0 = float(shot.x0)
      sy0 = float(shot.y0)
      sx1 = float(shot.x1)
      sy1 = float(shot.y1)
    var
      pts = newJArray()
      anyVisible = false
    for s in 0 ..< CosmeticFxShotSamples:
      let
        f = float(s) / float(CosmeticFxShotSamples - 1)
        wx = sx0 + (sx1 - sx0) * f
        wy = sy0 + (sy1 - sy0) * f
      if sim.fovVisibleAt(viewerIndex, int(wx), int(wy)):
        anyVisible = true
        pts.add(%*[int(wx), int(wy)])
      else:
        pts.add(newJNull())
    if not anyVisible:
      continue
    fx.add(%*{
      "kind": "tracer",
      "pts": pts,
      "age": sim.tickCount - shot.firedTick,
      "color": playerColorText(shot.color),
      "hit": shot.hit
    })
  for stain in sim.paintStains:
    if not sim.fovVisibleAt(viewerIndex, stain.x, stain.y):
      continue
    fx.add(%*{
      "kind": "stain",
      "x": stain.x,
      "y": stain.y,
      "color": playerColorText(stain.color),
      "onWall": stain.onWall
    })
  for deed in gloryDeeds:
    if deed.actorIndex < 0 or deed.actorIndex >= sim.players.len:
      continue
    if not sim.fovVisibleAt(viewerIndex, deed.x, deed.y):
      continue
    fx.add(%*{
      "kind": "glory",
      "tick": deed.tick,
      "word": deed.word,
      "amount": deed.amount,
      "team": teamText(deed.team),
      "self": deed.actorIndex == viewerIndex,
      "x": deed.x,
      "y": deed.y
    })
  if fx.len == 0:
    return ""
  $(%*{"fx": fx})

proc declarePlayerFailure(slot: int, message: string) =
  ## Publishes the game-declared terminal player failure the platform runner
  ## polls for (COGAME_PLAYER_FAILURE_URI -> player_failure.json), so a lobby
  ## no-show or mid-form drop is charged to the seat that caused it instead of
  ## poisoning the whole episode unattributed. Best-effort: the abort that
  ## follows must never be masked by a declaration write failure, and outside
  ## the platform (env unset) this is a no-op.
  try:
    writeCogameEnv(
      "COGAME_PLAYER_FAILURE_URI",
      $(%*{"failed_policy_index": slot, "message": message}),
      "application/json"
    )
  except CatchableError as e:
    echo "player-failure declaration failed: ", e.msg

proc parseRegistration(
  text: string
): tuple[ok: bool, prompt, scripted, policy: string] =
  ## A seat's ONE Sprite v1 chat message, read as its registration:
  ##   {"type":"register","prompt":"…","scripted":"holdline"|null,"policy":"…"}
  ## Anything that is not that object is not a registration.
  result = (false, "", "", "")
  if text.len == 0 or text[0] != '{':
    return
  var node: JsonNode
  try:
    node = parseJson(text)
  except CatchableError:
    return
  if node.kind != JObject or node{"type"}.getStr() != "register":
    return
  result.ok = true
  result.prompt = node{"prompt"}.getStr()
  if not node{"scripted"}.isNil and node{"scripted"}.kind == JString:
    result.scripted = node{"scripted"}.getStr()
  result.policy = node{"policy"}.getStr()

proc squadAlias(sim: SimServer, order: int): string =
  ## The ANONYMOUS in-game name of the cog that will occupy slot `order`,
  ## resolved from the config alone so it is identical on every replay.
  toUpperAscii(teamText(sim.teamForSlot(order))) & "-" &
    IdentityNames[sim.slotIdentityIndex(order)]

proc bodyPoint(player: Player): BodyPoint =
  (player.x + CollisionW div 2, player.y + CollisionH div 2)

proc bodyWindup(player: Player): Option[int] =
  if player.windupBrads >= 0:
    some(player.windupBrads)
  else:
    none(int)

proc bodyVeteranMarker(player: Player): bool =
  player.level >= AceLevel

proc bodyVisibleWeapon(player: Player): Option[BodyWeapon] =
  ## Visible player tracks have sim truth. Unknown remains representable as
  ## `none(BodyWeapon)` for future fog channels; this live visual channel must
  ## not collapse unknown to gun.
  if player.arcTicksLeft > 0 or player.hasSprayPaint:
    some(bwSpray)
  elif player.hasGrenade:
    some(bwGrenade)
  else:
    some(bwGun)

proc shellSelfState(sim: SimServer, playerIndex: int): BodySelfState =
  let player = sim.players[playerIndex]
  # GLORY L3+ (levelMaxHp): a leveled cog's own hpFrac must read against its
  # real (buffed) ceiling, not the unleveled base -- otherwise its own
  # perception of "how hurt am I" is wrong the moment it out-levels the base.
  let maxHp = max(1, sim.config.maxHpFor(player.team, player.perks, player.level))
  let hp = player.hp + player.shieldHp
  BodySelfState(
    pos: player.bodyPoint,
    hp: hp,
    hpFrac: float(hp) / float(maxHp + ShieldLayerHp),
    lives: (if sim.config.brMode: none(int) else: some(player.lives)),
    aimBrads: player.aimBrads,
    fireCooldown: player.fireCooldown,
    fireWindup: player.fireWindup,
    windup: player.bodyWindup,
    hasGrenade: player.hasGrenade,
    hasShield: player.hasShield,
    shieldHp: player.shieldHp,
    hasSprayPaint: player.hasSprayPaint,
    arcTicksLeft: player.arcTicksLeft,
    alive: player.alive,
    carrying: player.carryingFlag,
    downed: player.downed)

proc shellPartner(sim: SimServer, playerIndex: int): Option[PartnerSample] =
  let player = sim.players[playerIndex]
  for otherIndex, other in sim.players:
    if otherIndex != playerIndex and other.team == player.team and
        other.joinOrder >= 0 and other.joinOrder < MaxPlayers:
      return some(PartnerSample(
        seat: uint8(other.joinOrder),
        team: other.team,
        pos: other.bodyPoint,
        aimBrads: other.aimBrads,
        alive: other.alive,
        downed: other.downed,
        # PERCEPTION(glory-2 §17): gated on frameLoadoutFlags, never
        # lootStart -- other.hasGun/hasHopper are the sim TRUTH in every
        # mode (constant true/true outside lootStart); this flag controls
        # only whether the partner grant may carry them. Dark by
        # construction: both sit at their zero value (false) whenever the
        # flag is off, exactly like every other perception field here.
        hasGun: sim.config.frameLoadoutFlags and other.hasGun,
        hasHopper: sim.config.frameLoadoutFlags and other.hasHopper))
  none(PartnerSample)

type
  ShellConeObservation = object
    eventId: uint64
    attackerIndex: int
    attackerSeat: int
    origin: BodyPoint
    aimBrads: int
    victimSlots: uint32

  ShellObservationFrame = object
    cones: seq[ShellConeObservation]

proc shellObservationFrame(sim: SimServer): ShellObservationFrame =
  ## Compute the authoritative victim set once per active cone and body
  ## boundary. Every seat projection below reuses this immutable frame.
  for attackerIndex, attacker in sim.players:
    if not attacker.alive or attacker.arcTicksLeft <= 0 or
        attacker.joinOrder < 0 or attacker.joinOrder >= MaxPlayers:
      continue
    var victimSlots = 0'u32
    for victimIndex in sim.selectArcVictims(attackerIndex):
      let slot = sim.players[victimIndex].joinOrder
      if slot >= 0 and slot < MaxPlayers:
        victimSlots = victimSlots or (1'u32 shl slot)
    let activationTick = sim.tickCount -
      (SprayPaintActiveTicks - attacker.arcTicksLeft)
    result.cones.add ShellConeObservation(
      eventId: packedObservationEventId(
        activationTick, SprayConeObservationKind, attacker.joinOrder, -1, 0),
      attackerIndex: attackerIndex,
      attackerSeat: attacker.joinOrder,
      origin: attacker.bodyPoint,
      aimBrads: attacker.arcAimBrads,
      victimSlots: victimSlots)

proc currentSeatInAudience(sim: SimServer, slot: int,
                           audience: openArray[ObservationAudienceSeat]): bool =
  if slot < 0 or slot >= MaxPlayers:
    return false
  for admitted in audience:
    if admitted.slot.int == slot and
        admitted.lifeGeneration == sim.seatLifeGenerations[slot]:
      return true
  false

proc bodyShoutIdentityName(sim: SimServer,
                           observation: ShoutObservation): string =
  ## The body keeps the source slot stable but only names the original live
  ## author. Sprite rendering continues to use roster.shoutIdentityName.
  let slot = observation.sourceSlot
  if slot < 0 or slot >= MaxPlayers or
      sim.seatConnectionGenerations[slot] !=
        observation.sourceConnectionGeneration:
    return IdentityNameUnknown
  for player in sim.players:
    if player.joinOrder == slot and player.address == observation.address:
      return IdentityNames[sim.slotIdentityIndex(slot)]
  IdentityNameUnknown

proc shellBodyInputs(sim: var SimServer, playerIndex: int,
                          observations: ShellObservationFrame): BodyTickInputs =
  let player = sim.players[playerIndex]
  discard sim.refreshPlayerFov(playerIndex)
  result.self = sim.shellSelfState(playerIndex)
  result.partner = sim.shellPartner(playerIndex)
  for targetIndex, target in sim.players:
    if targetIndex == playerIndex or not target.alive:
      continue
    if target.team == player.team:
      continue
    if target.joinOrder < 0 or target.joinOrder >= MaxPlayers:
      continue
    if sim.playerVisibleTo(playerIndex, targetIndex):
      result.visibleTracks.add(BodyTrackUpdate(
        seat: target.joinOrder,
        pos: target.bodyPoint,
        team: target.team,
        # some(): today's sim always exposes a readable aim for any track it
        # emits (the aimBrads ruling); the omit case is reserved for future
        # non-visual channels.
        aimBrads: some(target.aimBrads),
        hpKnown: some(target.hp + target.shieldHp),
        shielded: target.hasShield,
        weapon: target.bodyVisibleWeapon,
        veteranMarker: target.bodyVeteranMarker,
        tick: uint32(sim.tickCount + 1),
        downed: target.downed))
  # Item sightings: every fixed pickup point inside this seat's fog, whether
  # the item is there or taken (the body's item memory keeps "seen empty"
  # facts so a play stops chasing a kit someone else grabbed). Until this
  # pass existed nothing fed BodyTickInputs.sightedItems outside the tests,
  # so body.items -- and with it the play view's `items` array -- was always
  # empty in live play: supply_run and loot could never see a pickup.
  template sight(spawns: seq[PickupSpawn], itemKind: BodyItemKind) =
    for spawn in spawns:
      if sim.fovVisibleAt(playerIndex, spawn.x, spawn.y):
        result.sightedItems.add(ItemSighting(kind: itemKind,
          pos: (spawn.x, spawn.y), present: spawn.present,
          tick: uint32(sim.tickCount + 1)))
  sight(sim.grenadeSpawns, bikGrenade)
  sight(sim.medKitSpawns, bikMedkit)
  sight(sim.shieldSpawns, bikShield)
  sight(sim.sprayPaintSpawns, bikSpray)
  sight(sim.barrierSpawns, bikBarrier)
  # PERCEPTION(glory-2 §17): the lootStart marker/hopper crates -- same
  # sight() template, same fog rule as every family above. No separate
  # gate needed: sim.weaponSpawns/hopperSpawns are themselves empty
  # whenever lootStart is dark (resetLootCrates's own contract), so a
  # dark game sights nothing here, identically to every other family.
  sight(sim.weaponSpawns, bikGun)
  sight(sim.hopperSpawns, bikHopper)
  # GVNEXT(drop): ground drops are sighted exactly like the fixed pickups
  # above — same fog test, same ItemSighting shape — so a play can SEE a
  # dropped can/marker and walk to it. Without this the open-steal ruling is
  # unreachable for policies: they would be stealing blind.
  #
  # A dropped BANDAGE is not sighted, because BodyItemKind has no bandage
  # member and `sim.bandageSpawns` is not sighted either: dropped bandages
  # are exactly as visible to a play as placed ones, which keeps the two
  # halves of the bandage economy consistent rather than inventing a
  # perception the pickup side does not have.
  for item in sim.droppedItems:
    if not sim.fovVisibleAt(playerIndex, item.x, item.y):
      continue
    let sighted =
      case item.kind
      of dkSpray: bikSpray
      of dkGun: bikGun
      of dkHopper: bikHopper
      of dkGrenade: bikGrenade
      of dkBarrier: bikBarrier
      of dkBandage: continue
    result.sightedItems.add(ItemSighting(kind: sighted,
      pos: (item.x, item.y), present: true,
      tick: uint32(sim.tickCount + 1)))

  let
    viewerSlot = player.joinOrder
    bodyTick = uint32(max(0, sim.tickCount + 1))
  for observation in sim.publicKillObservations:
    result.killFeed.add KillEvent(
      eventId: observation.eventId,
      tick: uint32(max(0, observation.tick)),
      killerTeam: observation.killerTeam,
      victimSeat: observation.victimSlot)
  if viewerSlot >= 0 and viewerSlot < MaxPlayers:
    for observation in sim.aggressorObservations:
      if observation.victimSlot == viewerSlot and
          observation.victimLifeGeneration ==
            sim.seatLifeGenerations[viewerSlot]:
        result.aggressorEvents.add AggressorEvent(
          eventId: observation.eventId,
          tick: uint32(max(0, observation.tick)),
          dirBrads: observation.dirBrads,
          seat: (if observation.attackerSlot >= 0:
            some(observation.attackerSlot) else: none(int)))

    for grenade in sim.airborneGrenades:
      let position = grenade.grenadePosition(sim.tickCount)
      if player.alive and sim.fovVisibleAt(playerIndex, position.x, position.y):
        result.hazards.grenades.add BodyGrenadeHazard(
          eventId: grenade.observationId,
          coversSelf: sim.grenadeCoversPlayer(
            playerIndex, grenade.tx, grenade.ty),
          pos: position,
          predictedBlastPos: (grenade.tx, grenade.ty),
          ticksToBlast: max(0,
            grenade.launchTick + grenade.flightTicks - sim.tickCount))
      if grenade.throwerSlot == viewerSlot:
        result.hazards.ownThrow = some(BodyOwnThrow(
          eventId: grenade.observationId,
          target: (grenade.tx, grenade.ty),
          releaseTick: uint32(max(0, grenade.launchTick)),
          blastRadius: GrenadeBlastRadius))

    for observation in sim.blastObservations:
      if sim.currentSeatInAudience(viewerSlot, observation.audience):
        let (dx, dy) = blastOffset(
          observation.tick, observation.x, observation.y)
        result.hazards.blastCues.add BodyBlastCue(
          eventId: observation.eventId,
          coversSelf:
            (observation.coveredSlots and (1'u32 shl viewerSlot)) != 0,
          pos: (observation.x + dx, observation.y + dy),
          tick: uint32(max(0, observation.tick)))

    for observation in sim.sprayImpactObservations:
      if sim.currentSeatInAudience(viewerSlot, observation.audience):
        let (dx, dy) = shotImpactOffset(
          observation.tick, observation.x, observation.y)
        result.hazards.sprays.add BodySprayHazard(
          eventId: observation.eventId,
          coversSelf: true,
          tick: uint32(max(0, observation.tick)),
          kind: bshAnonymousImpact,
          impactPos: (observation.x + dx, observation.y + dy),
          incomingDirBrads: observation.incomingDirBrads)

    if player.alive:
      for cone in observations.cones:
        if cone.attackerIndex < 0 or cone.attackerIndex >= sim.players.len:
          continue
        if cone.attackerIndex == playerIndex:
          continue
        if not sim.playerVisibleTo(playerIndex, cone.attackerIndex):
          continue
        result.hazards.sprays.add BodySprayHazard(
          eventId: cone.eventId,
          coversSelf: (cone.victimSlots and (1'u32 shl viewerSlot)) != 0,
          tick: bodyTick,
          kind: bshVisibleCone,
          attackerSeat: cone.attackerSeat,
          origin: cone.origin,
          aimBrads: cone.aimBrads,
          reachPx: SprayPaintReach,
          maxWidthPx: SprayPaintMaxWidth)

  for shout in sim.recentShouts:
    if not sim.shoutAudibleTo(playerIndex, shout):
      continue
    for observation in sim.shoutObservations:
      if observation.address == shout.address and observation.tick == shout.tick:
        let (dx, dy) = shoutOffset(shout)
        result.shouts.add ShoutEvent(
          eventId: observation.eventId,
          team: shout.team,
          slotLetter: sim.bodyShoutIdentityName(observation),
          text: shout.text,
          pos: (shout.x + dx, shout.y + dy),
          tick: uint32(max(0, shout.tick)))
        break

proc shellBodyInputs(sim: var SimServer, playerIndex: int): BodyTickInputs =
  sim.shellBodyInputs(playerIndex, sim.shellObservationFrame())

proc shellVelocity(sim: SimServer, playerIndex: int): int =
  let player = sim.players[playerIndex]
  let speedScale = if player.carryingFlag: sim.config.carrierSpeedPct else: 100
  (sim.config.maxSpeedFor(player.team, player.perks) * speedScale div 100) *
    sim.paintSpeedPct(playerIndex) div 100

proc ticksToNextZoneShrink(sim: SimServer, elapsedTicks: int): int =
  if sim.config.zonePhases.len == 0:
    return high(int) div 4
  var remaining = max(0, elapsedTicks)
  for phase in sim.config.zonePhases:
    if remaining < phase.waitTicks:
      return phase.waitTicks - remaining
    remaining -= phase.waitTicks
    if remaining < phase.shrinkTicks:
      return 0
    remaining -= phase.shrinkTicks
  high(int) div 4

proc shellZonePhase(sim: SimServer, elapsedTicks: int): int =
  if sim.config.zonePhases.len == 0:
    return 0
  var remaining = max(0, elapsedTicks)
  for index, phase in sim.config.zonePhases:
    if remaining < phase.waitTicks:
      return index + 1
    remaining -= phase.waitTicks
    if remaining < phase.shrinkTicks or phase.shrinkTicks <= 0:
      return index + 1
    remaining -= phase.shrinkTicks
  sim.config.zonePhases.len

proc shellAliveTeams(sim: SimServer): int =
  var seen: set[Team]
  for player in sim.players:
    if player.alive and player.team notin seen:
      seen.incl(player.team)
      inc result

proc rectCenter(rect: MapRect): BodyPoint =
  (rect.x + rect.w div 2, rect.y + rect.h div 2)

proc shellRotateTarget(selfPos: BodyPoint, zone: MapRect): BodyPoint =
  ## Shell fallback fact: pick a short validated goal in the direction of the
  ## next zone. The body still owns path planning and the final movement mask.
  const MaxRotateStepPx = 192
  let target = zone.rectCenter
  let dx = target.x - selfPos.x
  let dy = target.y - selfPos.y
  let distance = max(abs(dx), abs(dy))
  if distance <= MaxRotateStepPx:
    target
  else:
    (selfPos.x + dx * MaxRotateStepPx div distance,
     selfPos.y + dy * MaxRotateStepPx div distance)

proc shellFallbacks(sim: SimServer,
                         selfPos: BodyPoint): BrDefaultFallbacks =
  # Zone facts cross into the shell as rects and tick deltas on the schedule's
  # elapsed clock, which is 0 until startGame.
  let elapsed = sim.gameTicksElapsed()
  let zone =
    if sim.config.zonePhases.len == 0:
      (cur: MapRect(x: 0, y: 0, w: sim.gameMap.width, h: sim.gameMap.height),
       next: MapRect(x: 0, y: 0, w: sim.gameMap.width, h: sim.gameMap.height),
       dps: 0)
    else:
      sim.zoneRectAndDps(elapsed)
  BrDefaultFallbacks(
    currentZone: zone.cur,
    nextZone: zone.next,
    ticksToNextShrink: sim.ticksToNextZoneShrink(elapsed),
    zonePhase: sim.shellZonePhase(elapsed),
    zoneDps: zone.dps,
    rotateTarget: some(shellRotateTarget(selfPos, zone.next)))

proc shellZoneLogLine(sim: SimServer): string =
  let
    elapsed = sim.gameTicksElapsed()
    zone = if sim.config.zonePhases.len == 0:
      (cur: MapRect(x: 0, y: 0, w: sim.gameMap.width, h: sim.gameMap.height),
       next: MapRect(x: 0, y: 0, w: sim.gameMap.width, h: sim.gameMap.height),
       dps: 0)
    else:
      sim.zoneRectAndDps(elapsed)
    field = zoneArrivalFieldDebugState()
  "SHELL_ZONE tick=" & $(sim.tickCount + 1) &
    " elapsed=" & $elapsed &
    " phases=" & $sim.config.zonePhases.len &
    " phase=" & $sim.shellZonePhase(elapsed) &
    " current=[" & $zone.cur.x & "," & $zone.cur.y & "," &
      $zone.cur.w & "," & $zone.cur.h & "]" &
    " next=[" & $zone.next.x & "," & $zone.next.y & "," &
      $zone.next.w & "," & $zone.next.h & "]" &
    " dps=" & $zone.dps &
    " arrival_built=" & $field.built &
    " arrival_grid=" & $field.gridW & "x" & $field.gridH &
    " arrival_cells=" & $field.cells &
    " edge_band_shipped=" & $field.shipped

type ShellControlSet = tuple[
  controls: seq[SlotControl],
  teams: seq[Team],
  names: seq[string],
  hasPlaySeat: bool
]

proc shellControlSet(config: GameConfig): ShellControlSet =
  for slot in config.slots:
    result.controls.add(slot.control)
    result.teams.add(slot.team)
    result.names.add(slot.name)
    if slot.control == scPlay:
      result.hasPlaySeat = true

proc resetShellForSim(episode: var ShellEpisode,
                           replayLoaded: bool,
                           config: GameConfig,
                           sim: SimServer,
                           reason: string,
                           configJson = "") =
  let controlSet = config.shellControlSet()
  if not replayLoaded and config.season2Shell and controlSet.hasPlaySeat:
    let mapName =
      if sim.gameMap.name.len > 0: sim.gameMap.name else: config.mapPath
    episode.resetShellEpisode(
      config.season2Shell, config.brMode, controlSet.controls,
      newBodyMap(sim.gameMap), config.gunRange, controlSet.teams,
      mapName, config.viewIntervalTicks, controlSet.names)
    echo "SHELL enabled play_seats=", episode.seats.len, " reset=", reason
    let configured =
      episode.configureDemoPlayFromJsonWithReplayIdentities(configJson)
    for line in configured.lines:
      echo line
    for identity in configured.callIdentities:
      discard queueAcceptedPlayCallIdentity(
        int(identity.seat), some(identity), tickTime(sim.tickCount))
  else:
    episode.closeShellEpisode()
    episode = ShellEpisode()

proc finishAndCopyProfileTrace(done: var bool) =
  if done or not profileEnabled():
    return
  done = true
  finishProfileTrace()
  let workDir = getEnv("COWORLD_WORKDIR")
  if workDir.len > 0 and fileExists(ProfileTracePath):
    let destination = workDir / "logs" / "profile-trace.json"
    createDir(destination.parentDir)
    copyFile(ProfileTracePath, destination)
    echo "Profile trace copied: ", destination

proc runServerLoop*(
  host = DefaultHost,
  port = DefaultPort,
  initialConfig = defaultGameConfig(),
  saveReplayPath = "",
  loadReplayPath = "",
  saveScoresPath = "",
  runtimeConfig = RuntimeConfig()
) =
  initAppState()
  if saveReplayPath.len > 0 and loadReplayPath.len > 0:
    raise newException(ReplayError, "Cannot save and load a replay together")
  var replayLoaded = loadReplayPath.len > 0
  var replayData =
    if replayLoaded:
      try:
        loadCtfReplay(loadReplayPath)
      except CatchableError as e:
        # A bad or version-mismatched replay must not kill the server: the
        # viewer would see a dead socket (frozen shell, 0/0 scrubber, empty
        # lives) with no explanation. Serve the empty lobby and say why.
        echo "replay load failed (serving without replay): ", e.msg
        replayLoaded = false
        CtfReplayData()
    else:
      CtfReplayData()
  var initializedReplay =
    if replayLoaded:
      initReplayRuntime(replayData, runtimeConfig.mismatchQuit)
    else:
      InitializedReplay()
  var config =
    if replayLoaded: move(initializedReplay.config)
    else: initialConfig
  var
    replayWriter = ctfReplayCodec.openReplayWriter(
      saveReplayPath,
      config.configJson(),
      CtfReplaySpec,
      shellEpisode = config.isPlaySeatEpisode(),
      shellSeatCount = (if config.isPlaySeatEpisode(): config.slots.len else: 0))
    # Per-cog last RECORDED direct-aim bearing, -1 = channel off. Lives beside
    # the writer it feeds, for the writer's whole life, because the aim stream
    # is deduped exactly like the mask stream: a record is written only when
    # the bearing changes and playback holds it in between.
    lastDirectAim: seq[int] = @[]
    replayPlayer =
      if replayLoaded:
        move(initializedReplay.player)
      else:
        ReplayPlayer()
  var profileTraceFinished = false
  startProfileTrace()
  defer:
    finishAndCopyProfileTrace(profileTraceFinished)
    replayWriter.closeReplayWriter()
    {.gcsafe.}:
      withLock appState.lock:
        for seat in 0 ..< appState.playIngress.len:
          if appState.config.isPlaySeat(seat):
            appState.playIngress[seat].binding.close()
  appState.replayLoaded = replayLoaded
  appState.replayServerMode = replayLoaded
  appState.config = config
  configurePlayIngress(config)
  installProductionPlayConsumers(config)
  recordStartupReplayUri(replayLoaded)

  # Tier-2 event sink. Off unless the platform configured a destination, so a
  # live server that nobody is analysing keeps paying nothing — which is the
  # property `emitEvent`'s `collectEvents` guard exists to preserve.
  #
  # file:// ONLY, and it fails loudly otherwise rather than silently dropping
  # the stream: the dispatcher writes this as a workdir path and the runner
  # uploads the file afterwards, so an http target would mean the contract
  # changed underneath us and the operator needs to know.
  let eventsPath = block:
    let uri = getEnv("COGAME_EVENTS_URI")
    if uri.len == 0:
      ""
    elif uri.startsWith("file://"):
      uri[7 .. ^1]
    else:
      raise newException(
        ValueError,
        "COGAME_EVENTS_URI must be a file:// path, got: " & uri
      )

  # Optional performance-metrics sink, same file:// contract as events.
  let metricsPath = block:
    let uri = getEnv("COGAME_METRICS_URI")
    if uri.len == 0:
      ""
    elif uri.startsWith("file://"):
      uri[7 .. ^1]
    else:
      raise newException(
        ValueError,
        "COGAME_METRICS_URI must be a file:// path, got: " & uri
      )

  var
    sim =
      if replayLoaded: move(initializedReplay.sim)
      else: initSimServer(config)
    lastTick = getMonoTime()
    collectedEvents: seq[SimEvent] = @[]
  sim.collectEvents = eventsPath.len > 0
  block:
    # Bake the supersampled spectator render caches (map, endzone fades,
    # soldier rotations) BEFORE the listener opens: a viewer's first-message
    # clock starts at its successful connect (the coworld certifier allows
    # only seconds), so nothing may be accepted until every frame the loop
    # will ever build can be assembled instantly.
    let warmStart = getMonoTime()
    sim.warmBoardRenderCaches()
    echo "board render caches baked in ",
      (getMonoTime() - warmStart).inMilliseconds, " ms"

  let httpServer = newServer(
    httpHandler,
    websocketHandler,
    workerThreads = 4
  )

  var
    serverThread: Thread[ServerThreadArgs]
    serverPtr = cast[ptr Server](unsafeAddr httpServer)
  createThread(
    serverThread,
    serverThreadProc,
    ServerThreadArgs(server: serverPtr, address: host, port: port)
  )
  httpServer.waitUntilReady()
  if hostedRuntime.enabled:
    startHostedSeats(port, config)

  # --- mux transport (RL training) -----------------------------------------
  # COGAME_MUX_SOCKET multiplexes every policy seat of this env over ONE Unix
  # domain socket (see ctf/mux.nim). Unset (prod, live play): no listener, no
  # behavior change anywhere.
  let muxSocketPath = getEnv("COGAME_MUX_SOCKET")
  if muxSocketPath.len > 0:
    if replayLoaded:
      raise newException(CtfError, "COGAME_MUX_SOCKET is not a replay-mode transport")
    startMux(muxSocketPath)
  defer: closeMux()
  var muxViewers: array[MaxMuxSeats, PlayerViewerState]

  # --- paintball squad mode -------------------------------------------------
  # `num_agents` seats drive `num_agents * cogsPerTeam` cogs. The seats join
  # exactly as the starter's players do (slots 0..num_agents-1, token-checked);
  # once they are all in, the server fills the rest of the squads with trusted
  # joins carrying only the cogs' ANONYMOUS aliases, and from then on every
  # actuator mask comes from the control layer rather than from a socket.
  let squadMode = not replayLoaded and config.squadModeConfigured()
  var
    engine =
      if squadMode: initDecisionEngine(sim) else: DecisionEngine()
    squadsBuilt = false
    squadForceStart = false
    lastTurnKey = -1
    episodeStart = getMonoTime()
    deadlineHit = false
    liveOverlays: seq[DebugOverlay] = @[]
    prevInputs: seq[InputState]
    liveSpeedIndex = config.liveSpeedIndex()
    gamesPlayed = 0
    serverMetrics = ServerMetrics()
    lastLobbyLeaverSlot = -1  ## last configured slot that left during Lobby;
                              ## blamed if the mid-form drop dissolves the match.
    broadcastTracker =
      if replayLoaded: move(initializedReplay.tracker)
      else: initBroadcastTracker()
    shellEpisode: ShellEpisode
    shellTiming: ShellTimingWindow

  # The shell is reachable only in a play-seat episode. The default-true
  # shell with an all-input roster leaves the zero value untouched and never
  # calls into the episode owner.
  shellEpisode.resetShellForSim(replayLoaded, config, sim, "startup",
    runtimeConfig.config)
  defer:
    shellEpisode.closeShellEpisode()

  while true:
    if hostedRuntime.enabled and not replayLoaded:
      # A policy-host that dies before its seat joins is that seat's fault:
      # declare it now rather than burning the lobby timeout unattributed.
      for exit in pollHostedSeats():
        if sim.phase != Lobby:
          continue
        # An invalid module is the policy's fault; any other pre-join exit
        # is the host's, and either way the lobby can never fill.
        if exit.code == HostedExitInvalidPolicy:
          declarePlayerFailure(exit.slot,
            hostedFailureMessage(exit.slot, exit.code))
        raise newException(CtfError,
          hostedFailureMessage(exit.slot, exit.code))
    var
      pendingReplayUri = ""
      sockets: seq[WebSocket] = @[]
      socketsToClose: seq[WebSocket] = @[]
      playerIndices: seq[int] = @[]
      inputs: seq[InputState]
      downInputs: seq[InputState]
      downInputMasks: seq[uint8]
      pressedInputMasks: seq[uint8]
      globalViewers: seq[WebSocket] = @[]
      globalStates: seq[GlobalViewerState] = @[]
      rewardViewers: seq[WebSocket] = @[]
      playerViewerStates: seq[PlayerViewerState] = @[]
      # Human seat takeovers this frame: the cog each human drives, and the
      # sockets that get that cog's view. Kept OUT of `sockets`, which carries
      # the readiness/pacing contract for roster players.
      drivers = initTable[int, WebSocket]()
      takeoverSockets: seq[WebSocket] = @[]
      takeoverCogs: seq[int] = @[]
      takeoverStates: seq[PlayerViewerState] = @[]
      # Where each human-driven cog's cursor is this frame, in map pixels.
      # Indexed BY COG so the step loop can re-derive the bearing after every
      # step — the cursor holds still, but the cog moves under it, and "points
      # wherever the mouse is" has to stay true while you walk.
      aimTargets: seq[tuple[valid: bool, x, y: int]] = @[]
      replayCommands: seq[char] = @[]
      replaySeekTicks: seq[int] = @[]
      shouldReset = false
      quitAfterFrame = false

    # The engine's own hard stop, checked before anything else this
    # iteration: `wallClockBudgetSeconds` is 57.5% of the assumed 1200 s
    # episodeTimeoutSeconds, so paintball always settles and scores itself
    # rather than being silently discarded for overrunning.
    if squadMode and not deadlineHit and
        (getMonoTime() - episodeStart).inSeconds.int >=
          config.wallClockBudgetSeconds:
      deadlineHit = true
      sim.endReason = ReasonDeadline
      sim.endRule = EndRuleWallClock
      let leader = sim.hillLeader()
      echo "wall-clock budget of ", config.wallClockBudgetSeconds,
        "s reached; settling the episode from the hill counts at this tick"
      sim.finishGame(leader.team, isDraw = leader.draw)
      quitAfterFrame = true

    {.gcsafe.}:
      withLock appState.lock:
        pendingReplayUri = appState.pendingReplayUri
        appState.pendingReplayUri = ""
        if pendingReplayUri.len > 0:
          appState.loadingReplayUri = pendingReplayUri
    if pendingReplayUri.len > 0:
      var
        pendingData: CtfReplayData
        pendingOk = true
      try:
        pendingData = loadReplayUri(pendingReplayUri)
      except CatchableError as e:
        # An unreadable or version-mismatched replay must not kill the serve
        # loop (it serves every connected viewer). Keep the current state and
        # log why the switch was refused.
        echo "replay switch failed (keeping current state): ", e.msg
        pendingOk = false
        {.gcsafe.}:
          withLock appState.lock:
            if appState.loadingReplayUri == pendingReplayUri:
              appState.loadingReplayUri = ""
      if pendingOk:
        replayData = pendingData
        initializedReplay = initReplayRuntime(
          replayData,
          runtimeConfig.mismatchQuit
        )
        config = move(initializedReplay.config)
        sim = move(initializedReplay.sim)
        replayPlayer = move(initializedReplay.player)
        broadcastTracker = move(initializedReplay.tracker)
        replayLoaded = true
        shellEpisode.resetShellForSim(
          replayLoaded, config, sim, "replay_switch")
        # The switched-in sim carries a new map, but the board render caches
        # are process-wide — without this, addMapBands keeps splicing the OLD
        # map's cached band bytes into every new viewer's init packet. Rebake
        # before publishing the switch so the first viewer doesn't pay the
        # supersampled bake inside the serve loop (same budget reasoning as
        # the startup warm above).
        invalidateBoardMapCaches()
        block:
          let warmStart = getMonoTime()
          sim.warmBoardRenderCaches()
          echo "board render caches rebaked in ",
            (getMonoTime() - warmStart).inMilliseconds, " ms"
        {.gcsafe.}:
          withLock appState.lock:
            appState.replayLoaded = true
            appState.config = config
            configurePlayIngress(config)
            installProductionPlayConsumers(config)
            appState.currentReplayUri = pendingReplayUri
            if appState.loadingReplayUri == pendingReplayUri:
              appState.loadingReplayUri = ""

    {.gcsafe.}:
      withLock appState.lock:
        appState.shellEpisodeInLobby = sim.phase == Lobby
        if not replayLoaded and appState.resetRequested:
          shouldReset = true
          appState.resetRequested = false
          appState.chatMessages.clear()
          appState.policyPageFlashes.clear()
        for websocket in appState.closedSockets:
          if not replayLoaded and
              sim.retainShellSocketLoss(websocket, prevInputs):
            continue
          if squadMode:
            # A seat that drops does NOT remove its cogs: the squad is fixed
            # for the whole episode, its directive source degrades to the
            # holdline baseline, and the seat revives on reconnect. Deleting
            # the row would renumber every later cog mid-replay.
            discard removeWebSocketState(websocket)
            continue
          if not replayLoaded and sim.phase == Lobby and
              websocket in appState.playerIndices:
            let leaverSlot = appState.playerSlots.getOrDefault(websocket, -1)
            if leaverSlot >= 0:
              lastLobbyLeaverSlot = leaverSlot
          if not replayLoaded and websocket in appState.playerIndices:
            let playerIndex = appState.playerIndices[websocket]
            if playerIndex >= 0 and playerIndex < sim.players.len:
              sim.recordGameAbandon(playerIndex)
              replayWriter.writeLeave(tickTime(sim.tickCount), playerIndex)
              if playerIndex < replayWriter.lastMasks.len:
                replayWriter.lastMasks.delete(playerIndex)
              if playerIndex < prevInputs.len:
                prevInputs.delete(playerIndex)
              if playerIndex < liveOverlays.len:
                liveOverlays.delete(playerIndex)
          sim.removePlayer(websocket)
        appState.closedSockets.setLen(0)
        if not replayLoaded and appState.kickRequests.len > 0:
          let requestedKicks = appState.kickRequests
          appState.kickRequests = @[]
          var socketsToKick: seq[WebSocket] = @[]
          for websocket, address in appState.playerAddresses.pairs:
            let identity = address.rewardAddress()
            for requestedIdentity in requestedKicks:
              if address == requestedIdentity or identity == requestedIdentity:
                appState.kickedIdentities[address] = true
                appState.kickedIdentities[identity] = true
                if websocket notin socketsToKick:
                  socketsToKick.add(websocket)
          for websocket in socketsToKick:
            if not replayLoaded and
                sim.terminallyTombstoneShellSeat(websocket, prevInputs):
              socketsToClose.add(websocket)
              continue
            if websocket in appState.playerIndices:
              let playerIndex = appState.playerIndices[websocket]
              if playerIndex >= 0 and playerIndex < sim.players.len:
                sim.recordGameAbandon(playerIndex)
                replayWriter.writeLeave(tickTime(sim.tickCount), playerIndex)
                if playerIndex < replayWriter.lastMasks.len:
                  replayWriter.lastMasks.delete(playerIndex)
                if playerIndex < prevInputs.len:
                  prevInputs.delete(playerIndex)
                if playerIndex < liveOverlays.len:
                  liveOverlays.delete(playerIndex)
            sim.removePlayer(websocket)
            socketsToClose.add(websocket)
        if squadMode and not squadsBuilt and sim.lobbyJoinTimedOut():
          # A seat that never connects does NOT end the episode. Report the
          # no-show to the platform (lowest missing slot only), then build the
          # squads anyway: that seat's cogs run the published holdline
          # baseline for the whole episode and both games play to full time.
          let stuckSlot = sim.nextPlayerSlot()
          declarePlayerFailure(
            stuckSlot,
            "player slot " & $stuckSlot & " never joined the lobby within " &
              $sim.config.lobbyJoinTimeoutTicks & " lobby ticks (~" &
              $(sim.config.lobbyJoinTimeoutTicks div TargetFps) &
              "s); its squad plays the holdline baseline"
          )
          squadForceStart = true
        if not replayLoaded and not squadMode and sim.lobbyJoinTimedOut():
          # Joins are strictly slot-sequential, so the seat the lobby is stuck
          # waiting on is exactly nextPlayerSlot(). Declare it before dying so
          # the platform charges the no-show to that policy (player_error with
          # failed_policy_index) instead of burning the episode timeout with
          # every seat punished and none attributed.
          let stuckSlot = sim.nextPlayerSlot()
          declarePlayerFailure(
            stuckSlot,
            "player slot " & $stuckSlot & " never joined the lobby within " &
              $sim.config.lobbyJoinTimeoutTicks & " lobby ticks (~" &
              $(sim.config.lobbyJoinTimeoutTicks div TargetFps) & "s)"
          )
          raise newException(
            CtfError,
            "lobby join timeout: slot " & $stuckSlot &
              " never joined within " & $sim.config.lobbyJoinTimeoutTicks &
              " lobby ticks"
          )
        if not replayLoaded and not squadMode and sim.shouldAbortFiniteMatch():
          # Playing/GameOver roster loss now resolves deterministically
          # inside sim.step (recorded leaves re-derive it in replays); only
          # the lobby dissolve and process exit stay live-server concerns.
          if sim.phase == Lobby:
            if lastLobbyLeaverSlot >= 0:
              declarePlayerFailure(
                lastLobbyLeaverSlot,
                "player slot " & $lastLobbyLeaverSlot &
                  " left during the lobby start countdown and dropped the " &
                  "finite match roster below minPlayers"
              )
            raise newException(
              CtfError,
              "finite match roster dropped below minPlayers before roles were assigned"
            )
          quitAfterFrame = true
        if sim.phase != Lobby:
          # A remembered lobby leaver is only blame-worthy while THIS lobby is
          # still forming; once a game starts (or the phase moves on) the slot
          # may be reassigned and must not be charged for a later dissolve.
          lastLobbyLeaverSlot = -1

        if not replayLoaded:
          var newSockets: seq[WebSocket] = @[]
          for websocket in appState.playerIndices.keys:
            if websocket.isPlayerWebSocket() and
                appState.playerIndices[websocket] == UnresolvedPlayerIndex:
              newSockets.add(websocket)
          var progressed = true
          while progressed:
            progressed = false
            var pendingPlayers: seq[PendingPlayerJoin] = @[]
            for websocket in newSockets:
              if websocket notin appState.playerIndices or
                  appState.playerIndices[websocket] != UnresolvedPlayerIndex:
                continue
              let address = appState.playerAddresses.getOrDefault(
                websocket,
                "unknown"
              )
              let identity = address.rewardAddress()
              if address in appState.kickedIdentities or
                  identity in appState.kickedIdentities:
                sim.removePlayer(websocket)
                socketsToClose.add(websocket)
                continue
              let
                slot = appState.playerSlots.getOrDefault(websocket, -1)
                token = appState.playerTokens.getOrDefault(websocket, "")
              if sim.phase == Lobby and
                  (sim.canAddPlayer() or slot >= 0 or token.len > 0):
                try:
                  pendingPlayers.add(sim.pendingPlayerJoin(websocket))
                except CtfError:
                  sim.removePlayer(websocket)
                  socketsToClose.add(websocket)
              else:
                appState.playerIndices[websocket] = -1
            for join in sim.admitPendingJoins(
                pendingPlayers, socketsToClose, liveOverlays):
              let admittedSlot = appState.playerSlots.getOrDefault(
                join.websocket, -1)
              if appState.config.isPlaySeat(admittedSlot):
                let ingressSeat = admittedSlot.playIngressSeat()
                if ingressSeat != nil:
                  ingressSeat[].playerIndex =
                    appState.playerIndices[join.websocket]
              if appState.config.isPlaySeatEpisode() and admittedSlot >= 0 and
                  admittedSlot < appState.seatPlayerIndices.len:
                appState.seatPlayerIndices[admittedSlot] =
                  appState.playerIndices[join.websocket]
              replayWriter.writeJoin(
                tickTime(sim.tickCount),
                appState.playerIndices[join.websocket],
                join.address,
                join.requestedSlot,
                join.token
              )
              while replayWriter.lastMasks.len < sim.players.len:
                replayWriter.lastMasks.add(0)
              progressed = true
            # Mux seats join through the same strictly slot-sequential
            # admission: a pending mux JOIN is seated exactly when its slot is
            # the next open one, interleaving freely with websocket joins
            # (external baseline bots keep using websockets).
            if muxState.enabled and sim.phase == Lobby:
              var muxJoins: seq[MuxJoinRequest] = @[]
              withLock muxState.lock:
                muxJoins = muxState.pendingJoins
              for join in muxJoins:
                if join.slot != sim.nextPlayerSlot():
                  continue
                # Same identity resolution as the websocket upgrade path: a
                # token that names a configured slot plays under that slot's
                # configured identity.
                let configuredName =
                  sim.config.configuredPlayerName(join.slot, join.token)
                let address =
                  if configuredName.len > 0: configuredName else: join.address
                var admittedIndex = -1
                try:
                  admittedIndex = sim.addPlayer(address, join.slot, join.token)
                except CtfError as error:
                  echo "mux: join for slot ", join.slot, " refused: ", error.msg
                withLock muxState.lock:
                  for i in 0 ..< muxState.pendingJoins.len:
                    if muxState.pendingJoins[i].slot == join.slot:
                      muxState.pendingJoins.delete(i)
                      break
                  if admittedIndex >= 0:
                    muxState.seats[join.slot].playerIndex = admittedIndex
                    muxState.seats[join.slot].ready = false
                if admittedIndex >= 0:
                  muxViewers[join.slot] = initPlayerViewerState()
                  replayWriter.writeJoin(
                    tickTime(sim.tickCount), admittedIndex, address,
                    join.slot, join.token)
                  while replayWriter.lastMasks.len < sim.players.len:
                    replayWriter.lastMasks.add(0)
                  while liveOverlays.len < sim.players.len:
                    liveOverlays.add(DebugOverlay())
                  progressed = true

          # --- squad construction ------------------------------------------
          # Once every seat is seated (or the lobby budget expired and a
          # no-show has been reported), fill the rest of both squads with
          # trusted joins. The cogs carry ONLY their anonymous aliases, so the
          # replay's join stream leaks no policy identity; the real names ride
          # in the config JSON and in the redacted `register` records.
          if squadMode and not squadsBuilt and sim.phase == Lobby and
              (sim.players.len >= config.numAgents or squadForceStart):
            for order in sim.players.len ..< sim.totalCogs():
              try:
                discard sim.addPlayer(
                  sim.squadAlias(order), order, "", trusted = true)
              except CtfError as error:
                echo "squad construction failed at cog ", order, ": ",
                  error.msg
                break
              replayWriter.writeJoin(
                tickTime(sim.tickCount), order, sim.squadAlias(order),
                order, "")
              while replayWriter.lastMasks.len < sim.players.len:
                replayWriter.lastMasks.add(0)
              while liveOverlays.len < sim.players.len:
                liveOverlays.add(DebugOverlay())
            squadsBuilt = sim.players.len >= sim.totalCogs()
            if squadsBuilt:
              for seat in 0 ..< config.numAgents:
                if seat < sim.players.len and seat <= sim.seatNames.high:
                  sim.seatNames[seat] = sim.players[seat].address
                  sim.seatPolicyKind[seat] = engine.policyKind(seat)
              echo "squads built: ", sim.players.len, " cogs, ",
                config.numAgents, " seats, regime ", regimeText(sim.regime)

        # (The Paintball KOTH squad-construction block that earlier ports of
        # this branch hand-skipped is REAL now: the season-2 wave-1 merge
        # brought the paintball lineage in, and the restored block sits
        # directly above.)
        #
        # The seat-liveness-board populate call was ALSO hand-skipped on this
        # port (see git blame on this comment) -- the SeatSnapshot type,
        # seatBoard field, and seatWaitTicks/migratePendingTakeovers procs
        # auto-merged in and still compiled, so nothing errored, but with the
        # board never written the /takeover/seat PICKER route answered "no
        # candidate" (-1) forever, on EVERY config, which pushed every Free
        # Play arrival onto the app's own blind local fallback pick (no
        # aliveness information at all) instead of this engine's live one.
        # THIS is the seat-resolution delay family's root cause on the
        # engine side: restored here, plus a brMode-aware ranking
        # (pickFreeplaySeat/seatWaitTicks/migratePendingTakeovers all take a
        # `preferAlive` param now) -- the un-inverted ranking would have
        # confidently pointed every BR arrival at whichever cog is
        # PERMANENTLY eliminated (brMode death forces respawnTimer=0
        # forever, sim.nim's killPlayer), which is worse than the blind
        # fallback it replaces, not better.
        # Already inside this loop's own `withLock appState.lock:` (opened
        # above this whole admission block) -- appState.seatBoard is written
        # directly, never through a second acquire, which would deadlock on
        # a non-recursive Lock.
        if not replayLoaded and appState.config.allowSeatTakeover:
          var board: seq[SeatSnapshot] = @[]
          for i in 0 ..< sim.players.len:
            board.add(SeatSnapshot(
              seat: sim.players[i].joinOrder,
              cog: i,
              alive: sim.players[i].alive,
              respawnTimer: sim.players[i].respawnTimer))
          appState.seatBoard = board
          migratePendingTakeovers(appState.seatBoard, appState.config.brMode)
        # ---- seat takeover: resolve each seat, land pending swaps --------
        # A pending takeover goes live on its cog's next false -> true `alive`
        # edge. That is the ONE clean moment: the human always starts a life
        # at spawn and no cog is ever body-snatched mid-fight. The same edge
        # covers a new match — resetToLobby empties the roster (cog -1, so
        # "not alive"), and the seat's first spawn of the next match is the
        # edge — so serve-forever needs no separate case.
        #
        # brMode is the one exception: a single-life elimination cog only
        # ever goes true -> false, once, on elimination -- it never respawns,
        # so the edge above can never fire for a seat that is already alive
        # when the human arrives (the normal BR case). advanceSeatTakeover's
        # `instant` flag lands those seats on the first sampled frame instead.
        if not replayLoaded and appState.takeovers.len > 0:
          for websocket, takeover in appState.takeovers.mpairs:
            var cog = -1
            for i in 0 ..< sim.players.len:
              if sim.players[i].joinOrder == takeover.seat:
                cog = i
                break
            let nowAlive = cog >= 0 and sim.players[cog].alive
            if cog >= 0:
              takeover.cogX = sim.players[cog].x
              takeover.cogY = sim.players[cog].y
            if takeover.advanceSeatTakeover(cog, nowAlive, appState.config.brMode):
              echo "seat takeover live: ", takeover.name, " drives seat ",
                takeover.seat, " (cog ", takeover.cog, ")"
            if takeover.active and takeover.cog >= 0:
              drivers[takeover.cog] = websocket
            if takeover.cog >= 0 and takeover.cog < sim.players.len:
              takeoverSockets.add(websocket)
              takeoverCogs.add(takeover.cog)
              takeoverStates.add(appState.playerViewers[websocket])
            takeover.aimBrads =
              if takeover.cog >= 0 and takeover.cog < lastDirectAim.len:
                lastDirectAim[takeover.cog]
              else:
                -1
            if takeover.active and takeover.directAim and takeover.cog >= 0 and
                appState.config.allowDirectAim:
              let viewer = appState.playerViewers[websocket]
              if viewer.hasMouse:
                while aimTargets.len <= takeover.cog:
                  aimTargets.add((false, 0, 0))
                aimTargets[takeover.cog] = (true, viewer.mouseX, viewer.mouseY)
        if not replayLoaded:
          inputs = newSeq[InputState](sim.players.len)
          downInputs = newSeq[InputState](sim.players.len)
          downInputMasks = newSeq[uint8](sim.players.len)
          pressedInputMasks = newSeq[uint8](sim.players.len)
        for websocket, playerIndex in appState.playerIndices.pairs:
          if not websocket.isPlayerWebSocket():
            continue
          sockets.add(websocket)
          playerIndices.add(playerIndex)
          playerViewerStates.add(appState.playerViewers[websocket])
          if replayLoaded:
            continue
          if squadMode:
            # Seats send NO inputs: every actuator mask comes from the
            # control layer below, indexed by COG. Sampling the socket here
            # would write a second, conflicting mask record per tick.
            appState.inputPressedMasks[websocket] = 0
            continue
          if shellEpisode.enabled and playerIndex >= 0 and
              playerIndex < sim.players.len:
            let slot = sim.players[playerIndex].joinOrder
            if slot >= 0 and slot < config.slots.len and
                config.slots[slot].control == scPlay:
              # A play socket supplies presence and receives its view; it can
              # never supply an actuator mask. The shell's body seatTick
              # handoff below is the sole source for this configured seat.
              appState.inputMasks[websocket] = 0
              appState.inputPressedMasks[websocket] = 0
              continue
          # THE SWAP, and the whole of it: while a human drives this cog the
          # seat's mask is read off the human's socket instead of the policy's.
          # Same cog, same team, same eight buttons, same replay record under
          # the same player index — only the source of the bits moves. The
          # policy socket is still drained every tick (so nothing piles up)
          # and still receives its view, which is what makes the reverse
          # handoff seamless: it never stopped playing.
          let inputSocket =
            if playerIndex >= 0 and playerIndex in drivers:
              drivers[playerIndex]
            else:
              websocket
          let pressedMask = appState.inputPressedMasks.getOrDefault(
            inputSocket,
            0
          )
          appState.inputPressedMasks[websocket] = 0
          appState.inputPressedMasks[inputSocket] = 0
          if playerIndex < 0 or playerIndex >= inputs.len:
            appState.playerViewers[websocket].pendingDebugSprites = @[]
            continue
          while liveOverlays.len < sim.players.len:
            liveOverlays.add(DebugOverlay())
          appState.playerViewers[websocket].drainPlayerDebugSprites(
            tickTime(sim.tickCount),
            playerIndex,
            replayWriter,
            liveOverlays[playerIndex]
          )
          let currentMask = appState.inputMasks.getOrDefault(inputSocket, 0)
          let appliedMask = currentMask or pressedMask
          inputs[playerIndex] = decodeInputMask(appliedMask)
          downInputs[playerIndex] = decodeInputMask(currentMask)
          downInputMasks[playerIndex] = currentMask
          pressedInputMasks[playerIndex] = pressedMask
          replayWriter.writeInputFrameMasks(
            tickTime(sim.tickCount),
            playerIndex,
            appliedMask,
            pressedMask
          )
          appState.lastAppliedMasks[websocket] = appliedMask
          if inputSocket != websocket and inputSocket in appState.takeovers:
            appState.takeovers[inputSocket].lastMask = appliedMask
            appState.takeovers[inputSocket].policyMask =
              appState.inputMasks.getOrDefault(websocket, 0)
        if muxState.enabled and not replayLoaded and not squadMode:
          # Mux seat inputs, sampled with the same down/pressed edge
          # semantics as the websocket loop above.
          withLock muxState.lock:
            for slot in 0 ..< MaxMuxSeats:
              if not muxState.seats[slot].joined:
                continue
              let playerIndex = muxState.seats[slot].playerIndex
              if playerIndex < 0 or playerIndex >= inputs.len:
                continue
              if shellEpisode.enabled and
                  playerIndex < sim.players.len:
                let playerSlot = sim.players[playerIndex].joinOrder
                if playerSlot >= 0 and playerSlot < config.slots.len and
                    config.slots[playerSlot].control == scPlay:
                  continue
              let pressedMask = muxState.seats[slot].pressedMask
              muxState.seats[slot].pressedMask = 0
              let currentMask = muxState.seats[slot].inputMask
              let appliedMask = currentMask or pressedMask
              inputs[playerIndex] = decodeInputMask(appliedMask)
              downInputs[playerIndex] = decodeInputMask(currentMask)
              downInputMasks[playerIndex] = currentMask
              pressedInputMasks[playerIndex] = pressedMask
              replayWriter.writeInputFrameMasks(
                tickTime(sim.tickCount),
                playerIndex,
                appliedMask,
                pressedMask
              )
        if not replayLoaded:
          # Registrations that cannot be applied YET are HELD, not dropped.
          # Joins are strictly slot-sequential, so a seat whose slot is not the
          # next open one waits for the lower slots — and the lobby sends
          # frames to a socket before it has been admitted, so both the seat's
          # first registration and the one it re-sends after its first frame
          # can arrive while its player index is still 0x7fffffff. Clearing the
          # table then discarded them for good and the champion played the
          # scripted holdline baseline for the whole episode with no `register`
          # record at all (paintball round 3, 2026-08-25: "player connected:
          # daveey-1" first, then only "seat 0 registered" twice). Bounded by
          # construction: one entry per live socket, dropped with the socket.
          var heldRegistrations: seq[(WebSocket, string)] = @[]
          for websocket, chatText in appState.chatMessages.pairs:
            let playerIndex = appState.playerIndices.getOrDefault(
              websocket,
              -1
            )
            if squadMode:
              # A seat's chat is its REGISTRATION, consumed here and never
              # applied as a shout or written to the replay chat stream: the
              # prompt is a secret. What the replay gets is a redacted
              # `register` record — the policy label and kind only. Any other
              # chat text from a seat is dropped: cogs shout, seats do not.
              if playerIndex < 0 or playerIndex >= config.numAgents:
                if websocket.isPlayerWebSocket() and
                    parseRegistration(chatText).ok:
                  heldRegistrations.add((websocket, chatText))
                continue
              let registration = parseRegistration(chatText)
              if not registration.ok:
                continue
              var policy = engine.seats[playerIndex]
              let firstRegistration = not policy.registered
              policy.registered = true
              policy.prompt = registration.prompt.truncateRunes(MaxPromptRunes)
              policy.isLlm = policy.prompt.len > 0
              policy.baseline = parseBaseline(registration.scripted)
              policy.label =
                if registration.policy.len > 0: registration.policy
                elif policy.isLlm: "prompt"
                else: $policy.baseline
              engine.seats[playerIndex] = policy
              if playerIndex <= sim.seatPolicyKind.high:
                sim.seatPolicyKind[playerIndex] =
                  engine.policyKind(playerIndex)
              # One `register` record and one log line per seat. The seat
              # re-sends its registration for the first ~10 s of frames (see
              # src/paintball_player.nim), so recording every copy would put
              # ten identical records in the replay and ten identical lines in
              # the game log.
              if firstRegistration:
                replayWriter.writeChat(
                  tickTime(sim.tickCount),
                  playerIndex,
                  registerRecord(
                    playerIndex,
                    teamText(sim.teamForSlot(playerIndex)),
                    policy.label,
                    engine.policyKind(playerIndex),
                    $policy.baseline
                  )
                )
                echo "seat ", playerIndex, " registered: kind=",
                  engine.policyKind(playerIndex), " baseline=", $policy.baseline
              continue
            if sim.applyShout(playerIndex, chatText):
              replayWriter.writeChat(
                tickTime(sim.tickCount),
                playerIndex,
                chatText
              )
          appState.chatMessages.clear()
          # The one-page-policy REFLASH drain, written in the shout drain's
          # shape on purpose: apply at a tick boundary, and record EXACTLY
          # what the sim accepted, stamped with the tick it was accepted on.
          # `applyPolicyPage` is the single predicate both this path and
          # playback consult, so the file can never claim a flash the sim
          # refused, nor omit one it took.
          for websocket, page in appState.policyPageFlashes.pairs:
            let playerIndex = appState.playerIndices.getOrDefault(
              websocket,
              -1
            )
            if sim.applyPolicyPage(playerIndex, page):
              replayWriter.writePolicyPageFlash(
                tickTime(sim.tickCount),
                playerIndex,
                page
              )
          appState.policyPageFlashes.clear()
          for (websocket, chatText) in heldRegistrations:
            appState.chatMessages[websocket] = chatText
        for websocket, state in appState.globalViewers.pairs:
          globalViewers.add(websocket)
          globalStates.add(state)
          if state.replaySeekTick >= 0:
            replaySeekTicks.add(state.replaySeekTick)
          for command in state.replayCommands:
            replayCommands.add(command)
          appState.globalViewers[websocket].replayCommands.setLen(0)
          appState.globalViewers[websocket].replaySeekTick = -1
        for websocket in appState.rewardViewers.keys:
          rewardViewers.add(websocket)

    for websocket in socketsToClose:
      websocket.disconnectWebSocket()

    if shouldReset:
      let rewardAccounts = sim.rewardAccounts
      inc config.seed
      sim = initSimServer(config)
      sim.collectEvents = eventsPath.len > 0
      shellEpisode.resetShellForSim(replayLoaded, config, sim, "reset",
        runtimeConfig.config)
      # One file describes ONE match. A reset that kept the previous match's
      # events would concatenate two games under a single episode id.
      collectedEvents.setLen(0)
      # The live chrome tracker (stakes #7/#9) is a brand-new-match object too:
      # a fresh SimServer means a fresh roster (possibly a different player
      # count), and the OLD tracker's per-index kills/deaths/alive arrays are
      # sized for the match that just ended. The replay path never needs this
      # reset -- one replay file is one match, so its tracker's lifetime never
      # crosses a reset -- this is the live-only case that owns it.
      broadcastTracker = initBroadcastTracker()
      liveOverlays = @[]
      sim.rewardAccounts = rewardAccounts
      prevInputs = @[]
      replayWriter.lastMasks = @[]
      sockets.setLen(0)
      playerIndices.setLen(0)
      rewardViewers.setLen(0)
      playerViewerStates.setLen(0)
      {.gcsafe.}:
        withLock appState.lock:
          appState.kickedIdentities.clear()
          landSeatTakeoversOnNewMatch()
          var reconnectSockets: seq[WebSocket] = @[]
          for websocket in appState.playerIndices.keys:
            if websocket.isPlayerWebSocket():
              reconnectSockets.add(websocket)
          for websocket in reconnectSockets:
            appState.playerIndices[websocket] = UnresolvedPlayerIndex
          var progressed = true
          while progressed:
            progressed = false
            var pendingPlayers: seq[PendingPlayerJoin] = @[]
            for websocket in reconnectSockets:
              if websocket notin appState.playerIndices or
                  appState.playerIndices[websocket] != UnresolvedPlayerIndex:
                continue
              let
                slot = appState.playerSlots.getOrDefault(websocket, -1)
                token = appState.playerTokens.getOrDefault(websocket, "")
              if not sim.canAddPlayer() and slot < 0 and token.len == 0:
                appState.playerIndices[websocket] = -1
                continue
              try:
                pendingPlayers.add(sim.pendingPlayerJoin(websocket))
              except CtfError:
                sim.removePlayer(websocket)
                socketsToClose.add(websocket)
            for join in sim.admitPendingJoins(
                pendingPlayers, socketsToClose, liveOverlays):
              appState.inputMasks[join.websocket] = 0
              appState.inputPressedMasks[join.websocket] = 0
              appState.lastAppliedMasks[join.websocket] = 0
              appState.playerReady[join.websocket] = false
              sockets.add(join.websocket)
              playerIndices.add(appState.playerIndices[join.websocket])
              appState.playerViewers[join.websocket] =
                initPlayerViewerState()
              playerViewerStates.add(appState.playerViewers[join.websocket])
              progressed = true
          replayWriter.lastMasks.setLen(sim.players.len)
          for websocket in appState.rewardViewers.keys:
            rewardViewers.add(websocket)

      let rewardPacket = sim.buildRewardPacket()
      if not replayLoaded and config.isPlaySeatEpisode():
        sim.pumpPlayOutbound(config, shellEpisode)
      var
        spritesOffFlags = newSeq[bool](sockets.len)
        playSocketFlags = newSeq[bool](sockets.len)
      {.gcsafe.}:
        withLock appState.lock:
          for i in 0 ..< sockets.len:
            spritesOffFlags[i] =
              appState.spritesOff.getOrDefault(sockets[i], false)
            playSocketFlags[i] = appState.config.isPlaySeat(
              appState.playerSlots.getOrDefault(sockets[i], -1))
      for i in 0 ..< sockets.len:
        if playSocketFlags[i]:
          continue
        var nextState: PlayerViewerState
        let framePacket = sim.buildSpriteProtocolPlayerUpdates(
          playerIndices[i],
          playerViewerStates[i],
          nextState,
          spritesOff = spritesOffFlags[i]
        )
        {.gcsafe.}:
          withLock appState.lock:
            if sockets[i] in appState.playerViewers:
              appState.playerViewers[sockets[i]] = nextState
        let wirePacket = dedupObjectPlacements(
          if spritesOffFlags[i]: framePacket.stripSpritePixels()
          else: framePacket,
          nextState.sentPlacements
        )
        serverMetrics.recordTraffic(playerIndices[i], wirePacket)
        try:
          if wirePacket.len == 0:
            # One binary message per tick is the frame contract — clients
            # count messages to advance. An all-deduped frame still ships,
            # as an empty message.
            sockets[i].send("", BinaryMessage)
          for chunk in global.chunkSpritePacket(wirePacket, MaxWsFrameBytes):
            sockets[i].send(blobFromBytes(chunk), BinaryMessage)
        except:
          {.gcsafe.}:
            withLock appState.lock:
              discard markSocketClosed(sockets[i])
      for websocket in rewardViewers:
        try:
          websocket.send(rewardPacket, TextMessage)
        except:
          {.gcsafe.}:
            withLock appState.lock:
              discard markSocketClosed(websocket)
      # The lobby always paces at wall clock: fast-forwarding here spins the
      # loop hot on whichever seats joined first, and the appState-lock churn
      # starves mummy's upgrade path so the remaining seats never finish
      # connecting (certifier deadlock at "waiting for players").
      discard runFrameLimiter(
        lastTick, false, sockets, playerIndices, sim.players.len)
      continue

    # ------------------------------------------------------------------
    #  PAINTBALL: the decision turn, then the control-compiled actuator
    #  masks. This is the determinism boundary — the control layer and the
    #  LLM live on THIS side of it, and only the masks below are recorded,
    #  so the wasm viewer re-derives the whole match from them without ever
    #  running either.
    # ------------------------------------------------------------------
    if squadMode and squadsBuilt and sim.phase == Playing:
      let
        elapsedSeconds = (getMonoTime() - episodeStart).inSeconds.int
        turnTicks = max(1, config.turnTicks)
        turnIndex = sim.gameTicksElapsed() div turnTicks
        turnKey = sim.gameIndex * 1_000_000 + turnIndex
      engine.ctl.observeEnemies(sim)
      if sim.gameTicksElapsed() mod turnTicks == 0 and turnKey != lastTurnKey:
        lastTurnKey = turnKey
        let turnsPerGame =
          if config.maxTicks > 0: max(1, config.maxTicks div turnTicks) else: 0
        let records = engine.turn(sim, turnIndex, turnsPerGame, elapsedSeconds)
        for record in records:
          replayWriter.writeChat(tickTime(sim.tickCount), 0, record)
        for seat in 0 ..< engine.directives.len:
          if not engine.haveDirective[seat]:
            continue
          let directive = engine.directives[seat]
          case directive.source
          of dsLlm: inc sim.llmTurns[min(seat, sim.llmTurns.high)]
          of dsFallback: inc sim.fallbackTurns[min(seat, sim.fallbackTurns.high)]
          of dsScripted: discard
          let record = directive.boundedDirectiveRecord(
            sim.gameIndex + 1, turnIndex, seat,
            teamText(sim.teamForSlot(seat)), regimeText(sim.regime))
          replayWriter.writeChat(tickTime(sim.tickCount), seat, record)
          sim.pushFeedDirective(record)
          sim.emitEvent(
            Directive, source = seat, weapon = $directive.source,
            amount = turnIndex, content = directive.note)
          # A cog's `say` is a REAL in-game shout: hashed state both sides
          # hear, so it is written to the replay chat stream by cog index and
          # re-applied identically at playback.
          for order in directive.orders:
            if order.say.len == 0:
              continue
            if sim.applyShout(order.cogIndex, order.say):
              replayWriter.writeChat(
                tickTime(sim.tickCount), order.cogIndex, order.say)
      # Compile one mask per COG, in index order, every tick.
      inputs = newSeq[InputState](sim.players.len)
      for cogIndex in 0 ..< sim.players.len:
        let seat = sim.cogSeat(cogIndex)
        var order: CogOrder
        var found = false
        if sim.seatCommands(seat, cogIndex) and seat < engine.directives.len and
            engine.haveDirective[seat]:
          for candidate in engine.directives[seat].orders:
            if candidate.cogIndex == cogIndex:
              order = candidate
              found = true
              break
        if not found:
          # Either this cog is a scripted teammate in a `visitor` game, or its
          # seat has no directive yet. Both play the published holdline
          # baseline, which is what "adapt to a partner you know the rules of"
          # means here.
          let scripted = engine.holdlineFor(sim, @[cogIndex])
          if scripted.orders.len > 0:
            order = scripted.orders[0]
            found = true
        if not found:
          continue
        let mask = engine.ctl.compileMask(sim, order, cogIndex)
        inputs[cogIndex] = decodeInputMask(mask)
        replayWriter.writeInputMaskChange(
          tickTime(sim.tickCount), cogIndex, mask)
      downInputs = inputs
    elif squadMode and squadsBuilt and sim.players.len > 0:
      # NOT playing (the lobby between the two games of an episode, or the
      # game-over hold): the server steps with all-zero inputs, so the replay
      # has to be told that. Without it, playback keeps re-applying the last
      # masks of the previous game and the first Playing tick of the next one
      # sees a different `prev` — which decides whether a fresh A press fires,
      # and diverges the hash chain at exactly that tick.
      for cogIndex in 0 ..< sim.players.len:
        replayWriter.writeInputMaskChange(tickTime(sim.tickCount), cogIndex, 0)

    var frameEvents = newJArray()
    # Drained once per frame below (same "drain, then setLen(0)" shape as
    # collectedEvents/sim.events just under this), and consumed ONLY by the
    # takeover send pass further down — the ordinary per-seat (policy) send
    # pass never reads it. Declared out here (not inside the `else:` step
    # loop) so it survives to that later pass; stays empty for a replay
    # frame, which is fine, since replay playback never has a takeover
    # socket to deliver it to (takeoverSockets is only ever populated on the
    # `not replayLoaded` path above).
    var frameShotFeedback: seq[ShotFeedbackFx] = @[]
    # Same drain shape and same reason as frameShotFeedback just above (a
    # one-shot queue, not a fading Fx seq, so it must survive across however
    # many steps this frame runs at playbackSpeed > 1): consumed only by the
    # takeover send pass's buildCosmeticFxPacket call further down.
    var frameGloryDeeds: seq[GloryDeedFx] = @[]
    if replayLoaded:
      frameEvents = replayPlayer.advanceReplayFrame(
        sim,
        broadcastTracker,
        replaySeekTicks,
        replayCommands
      )
    else:
      for command in replayCommands:
        liveSpeedIndex.applySpeedCommand(command)
      var
        stepPrevInputs = prevInputs
        stepInputs = inputs
        stepPressedInputMasks = pressedInputMasks
        lastStepInputs = prevInputs
      for _ in 0 ..< playbackSpeed(liveSpeedIndex):
        var shellSeatsThisTick = 0
        if config.isPlaySeatEpisode():
          drainPlayIngressAtTickBoundary(
            shellEpisode, uint32(sim.tickCount + 1),
            uploadWindowClosed = sim.phase >= Playing)
          sim.drainProductionLobbyChats()
          sim.drainProductionBallotCasts()
          replayWriter.drainShellReplayRecords(
            sim, tickTime(sim.tickCount))
        let phaseBeforeStep = sim.phase
        stepPrevInputs.clearPressedInputMasks(stepPressedInputMasks)
        if shellEpisode.enabled:
          var frames: seq[ShellSeatFrame]
          let observationFrame = sim.shellObservationFrame()
          for playerIndex, player in sim.players:
            let slot = player.joinOrder
            if slot < 0 or slot >= config.slots.len or
                config.slots[slot].control != scPlay:
              continue
            if slot < appState.seatTombstones.len and
                appState.seatTombstones[slot].presence == spTerminal:
              continue
            let bodyInputs = sim.shellBodyInputs(
              playerIndex, observationFrame)
            frames.add(ShellSeatFrame(
              seat: uint8(slot),
              playerIndex: playerIndex,
              present: true,
              playing: sim.phase == Playing,
              alive: player.alive,
              aliveTeams: sim.shellAliveTeams(),
              motionScale: sim.config.motionScale,
              velocity: sim.shellVelocity(playerIndex),
              bodyInputs: bodyInputs,
              defaultFallbacks: sim.shellFallbacks(bodyInputs.self.pos)))
          let shellTick = shellEpisode.step(
            frames, uint32(sim.tickCount + 1))
          shellSeatsThisTick = shellTick.masks.len
          shellTiming.addShellTiming(shellTick)
          retainProductionModuleStatuses(shellTick.moduleStatuses)
          retainProductionLadderOutcomes(
            shellTick.ladderStatuses, shellTick.retuned)
          for line in shellTick.playLogLines:
            echo line
          var shellMoving, shellAiming = 0
          for mask in shellTick.masks:
            let encoded = mask.input.encodeInputMask()
            if (encoded and (ButtonUp or ButtonDown or
                ButtonLeft or ButtonRight)) != 0:
              inc shellMoving
            if (encoded and (ButtonB or ButtonSelect)) != 0:
              inc shellAiming
            if mask.playerIndex < 0 or mask.playerIndex >= stepInputs.len:
              continue
            stepInputs[mask.playerIndex] = mask.input
            if mask.playerIndex < downInputs.len:
              downInputs[mask.playerIndex] = mask.input
            replayWriter.writeInputMaskChange(
              tickTime(sim.tickCount), mask.playerIndex,
              encoded)
          if shellTick.masks.len > 0 and (shellMoving > 0 or
              shellAiming > 0 or (sim.tickCount mod 24) == 0):
            echo "SHELL_MOVEMENT tick=", sim.tickCount + 1,
              " seats=", shellTick.masks.len,
              " moving=", shellMoving,
              " aiming=", shellAiming
          if getEnv("SHELL_ZONE_LOG") == "1" and
              (sim.tickCount < 5 or (sim.tickCount mod 60) == 0):
            echo sim.shellZoneLogLine()
          for install in shellTick.installs:
            echo install.formatInstall()
          for annotation in shellTick.annotations:
            if annotation.kind == akPlayFault:
              echo annotation.formatLifecycleAnnotation(
                shellEpisode.seatDisplayName(annotation.seat.int))
            replayWriter.writeAnnotation(annotation)
          # Cold-planning budget events print on the tick they happen; the
          # follower census prints once a second and on every event tick so
          # the two join by tick. The weapon-path census prints once a second.
          for event in shellTick.planBudget:
            echo event.formatPlanBudgetEvent()
          let secondBoundary = (sim.tickCount mod 24) == 0
          if shellTick.masks.len > 0:
            if (secondBoundary or shellTick.planBudget.len > 0) and
                (shellTick.nav.pendingPlans > 0 or
                 shellTick.nav.stalePathSeats.len > 0 or
                 shellTick.nav.noPathSeats.len > 0):
              echo formatNavSummary(uint32(sim.tickCount + 1), shellTick.nav)
            if secondBoundary:
              echo formatCombatSummary(uint32(sim.tickCount + 1),
                shellTick.combat)
          # The give-item HANDOFF drain, written in the reflash drain's
          # shape on purpose (see the policy-page drain above): declare at
          # this tick boundary, and record EXACTLY what the consent seam
          # accepted, stamped with the tick it was accepted on. The sim's
          # own declared state is the dedupe — the standing order restates
          # its declaration every tick, and only a difference is worth a
          # call, so an accepted declaration writes ONE record, a refused
          # one (dark gate, downed giver, no partner yet) writes nothing
          # and retries while the order stands, and a completed transfer
          # (the sim clears the declaration) re-declares under the still-
          # standing order. declareHandoff is the single predicate this
          # path and playback consult, so the file can never claim a
          # declaration the sim refused, nor omit one it took.
          for declared in shellTick.handoffs:
            if declared.playerIndex < 0 or
                declared.playerIndex >= sim.players.len:
              continue
            if sim.players[declared.playerIndex].giveDeclItem ==
                declared.item:
              continue
            if sim.declareHandoff(declared.playerIndex, declared.item):
              replayWriter.writeHandoffDeclaration(
                tickTime(sim.tickCount), declared.playerIndex, declared.item)
          # ALLIANCE (engine registration rewire, GameVersion 56): the
          # `pact` play's own declaration drain, same shape as the handoff
          # drain just above and for the same reason — the sim's own
          # currently-declared partner mask IS the dedupe (a standing
          # `pact` call restates its partners every tick; only a CHANGE is
          # worth a record), so an accepted declaration writes ONE replay
          # record and a refused one (wrong phase, dead/downed seat) writes
          # nothing and retries while the call stands. declarePactPartners
          # is the single predicate this path and playback consult, so the
          # file can never claim a declaration the sim refused, nor omit
          # one it took.
          for declared in shellTick.pactDeclarations:
            if declared.playerIndex < 0 or
                declared.playerIndex >= sim.players.len:
              continue
            if sim.pactDeclaredPartners[declared.playerIndex] ==
                pactPartnersMask(declared.partners):
              continue
            if sim.declarePactPartners(declared.playerIndex, declared.partners):
              replayWriter.writePactDeclaration(
                tickTime(sim.tickCount), declared.playerIndex,
                declared.partners)
        # ---- direct aim: point the turret, THEN run the tick ------------
        # The one write that makes a human's aim absolute instead of a
        # traverse. Re-derived per STEP, not per frame: at >1x the frame runs
        # several ticks and the cog moves under a still cursor between them.
        #
        # Recorded to the replay in the same breath as it is applied, because
        # this bearing is not a button any mask could carry — a PLAY replay
        # that dropped it would re-simulate the human's match with the turret
        # on its policy heading and every shot missing. Playback applies the
        # held bearing at the matching point in stepReplay, so the two
        # orderings are one ordering.
        if not replayLoaded and appState.config.allowDirectAim:
          for cog in 0 ..< sim.players.len:
            var brads = -1
            if cog < aimTargets.len and aimTargets[cog].valid and
                sim.players[cog].alive:
              brads = sim.players[cog].directAimBrads(
                aimTargets[cog].x, aimTargets[cog].y)
              sim.applyDirectAim(cog, brads)
            replayWriter.writeDirectAimChange(
              lastDirectAim, tickTime(sim.tickCount), cog, brads)
        # The paintball `fault` end conditions (design §End conditions rows 5
        # and 6), now live on this branch: squadMode and the EndRuleSimFault/
        # EndRuleHostError constants landed via this same main-merge (an
        # earlier revision of this file hand-skipped this wrap because
        # neither existed yet on the unmerged Paintball KOTH lineage — that
        # note is now stale). A tripped sim invariant or any other exception
        # out of the tick is NOT a silent non-zero exit there: the episode
        # ends here, both seats score 0.500 (roster.playerResultsJson's fault
        # branch), and the artifact block below still writes the partial
        # replay, the results and the events. A CLASSIC/BR game keeps its
        # historical behavior: an exception out of step() propagates and the
        # runner sees the crash, exactly as it did before this merge.
        var faultRule = ""
        let simStarted = getMonoTime()
        try:
          sim.step(stepInputs, stepPrevInputs)
        except SimGuardError as guard:
          if not squadMode:
            raise
          echo "paintball: SIM GUARD tripped at tick ", sim.tickCount, ": ",
            guard.msg
          faultRule = EndRuleSimFault
        except CatchableError as error:
          if not squadMode:
            raise
          echo "paintball: HOST ERROR at tick ", sim.tickCount, ": ",
            error.msg
          faultRule = EndRuleHostError
        let simNanoseconds = (getMonoTime() - simStarted).inNanoseconds
        if faultRule.len > 0:
          sim.endReason = ReasonFault
          sim.endRule = faultRule
          sim.phase = GameOver
          quitAfterFrame = true
          break
        let timingLine = shellTiming.finishShellTimingTick(
          uint32(sim.tickCount), shellSeatsThisTick, simNanoseconds)
        if timingLine.len > 0:
          echo timingLine
        if shellEpisode.enabled:
          # Death is observed immediately after the sim step that caused it,
          # so clear-on-death carries that completed tick rather than waiting
          # for the next actuator pass. This hook performs no second default,
          # body call, or mask handoff.
          var lifecycleFrames: seq[ShellSeatFrame]
          for playerIndex, player in sim.players:
            let slot = player.joinOrder
            if slot < 0 or slot >= config.slots.len or
                config.slots[slot].control != scPlay:
              continue
            if slot < appState.seatTombstones.len and
                appState.seatTombstones[slot].presence == spTerminal:
              continue
            let selfState = sim.shellSelfState(playerIndex)
            lifecycleFrames.add(ShellSeatFrame(
              seat: uint8(slot),
              playerIndex: playerIndex,
              present: true,
              playing: false,
              alive: player.alive,
              aliveTeams: sim.shellAliveTeams(),
              motionScale: sim.config.motionScale,
              velocity: sim.shellVelocity(playerIndex),
              bodyInputs: BodyTickInputs(self: selfState),
              defaultFallbacks: sim.shellFallbacks(selfState.pos)))
          for annotation in shellEpisode.observeDeaths(
              lifecycleFrames, uint32(sim.tickCount)):
            echo annotation.formatLifecycleAnnotation()
            replayWriter.writeAnnotation(annotation)
        if sim.collectEvents:
          # Drained every tick, like the extractor's walk: the sink is a plain
          # seq on the sim and would otherwise grow for the whole match.
          for event in sim.events:
            collectedEvents.add(event)
          sim.events.setLen(0)
        # Same drain shape as sim.events just above, for the private
        # shot-feedback channel (GameConfig.allowShotFeedback): empty on
        # every config that leaves the gate off, since applyFire/
        # resolveActiveArcCones/explodeGrenade only ever push to it when the
        # gate is on. Accumulated across every step this frame (playbackSpeed
        # can run several steps per frame), consumed once below by the
        # takeover send pass only.
        for fx in sim.shotFeedback:
          frameShotFeedback.add fx
        sim.shotFeedback.setLen(0)
        # Same drain shape, same reason, for the glory-toast queue
        # (GameConfig.allowCosmeticFx): empty whenever the gate is off,
        # since awardDeed's `fxActor` callers only push to it gated
        # (see GloryDeedFx's doc comment).
        for deed in sim.gloryDeeds:
          frameGloryDeeds.add deed
        sim.gloryDeeds.setLen(0)
        # Broadcast chrome's kill-feed/phase/gameover beats (stakes #7/#9):
        # the SAME diff-the-tracker-against-this-tick call the replay path
        # makes once per stepped tick via advanceReplayPlayback's callback,
        # so a >1x live speed still attributes every kill in the frame
        # instead of collapsing several ticks into one ambiguous marker.
        # Read-only against sim (see stepEvents/killerThisStep signatures) --
        # cannot touch gameHash, which is hashed just below on the same tick.
        sim.stepEvents(broadcastTracker, frameEvents)
        lastStepInputs = stepInputs
        stepPrevInputs = stepInputs
        stepPressedInputMasks.resetInputMasks()
        replayWriter.writeHash(uint32(sim.tickCount), sim.gameHash())
        if stepInputs.len > 0 and stepInputs != downInputs:
          for playerIndex, mask in downInputMasks:
            replayWriter.writeInputMaskChange(
              tickTime(sim.tickCount),
              playerIndex,
              mask
            )
          stepInputs = downInputs
        if config.maxGames > 0 and phaseBeforeStep != GameOver and
            sim.phase == GameOver:
          inc gamesPlayed
          if squadMode:
            # Archive this half and arm the next one's regime BEFORE the
            # lobby reset that precedes the next startGame.
            sim.gameHill.add(sim.hillTicks)
            sim.gameRegimes.add(sim.regime)
            sim.gameIndex = gamesPlayed
            if config.regimes.len > 0:
              sim.regime = config.regimes[min(gamesPlayed, config.regimes.high)]
            squadsBuilt = false
            lastTurnKey = -1
            echo "game ", gamesPlayed, " done; hill red=",
              sim.gameHill[^1][Red], " blue=", sim.gameHill[^1][Blue],
              "; next regime ", regimeText(sim.regime)
        if config.maxGames > 0 and gamesPlayed >= config.maxGames:
          quitAfterFrame = true
          break
        if sim.needsReregister:
          break
      prevInputs = lastStepInputs

    let rewardPacket = sim.buildRewardPacket()

    if not replayLoaded and config.isPlaySeatEpisode():
      sim.pumpPlayOutbound(config, shellEpisode)

    if not replayLoaded and sim.needsReregister:
      sim.needsReregister = false
      shellEpisode.resetShellForSim(
        replayLoaded, config, sim, "reregister", runtimeConfig.config)
      liveOverlays = @[]
      # A round transition WITHIN the same match (roster/tick count both
      # carry forward, unlike the full shouldReset above) -- resync rather
      # than reinit, the same "state jumped, don't diff across the jump"
      # move the replay path makes on its own seek/command jumps
      # (advanceReplayFrame's `if didSeek: tracker.resync(sim)`).
      broadcastTracker.resync(sim)
      {.gcsafe.}:
        withLock appState.lock:
          for websocket in appState.playerIndices.keys:
            if websocket.isPlayerWebSocket():
              appState.playerIndices[websocket] = UnresolvedPlayerIndex
          for websocket in appState.playerViewers.keys:
            # Bots/policies (spritesOff) keep the historical full wipe so
            # their observation stream stays byte-identical to before this
            # change. Human viewers get the soft reset: the map bands,
            # walkability mask, and HUD layers this socket already holds
            # survive the round transition (see
            # resetPlayerViewerStateForRound) instead of being re-sent from
            # scratch on every round — the cause of the multi-megabyte
            # per-round resend (and the mid-transfer socket teardowns it
            # produced) that this fix targets.
            if appState.spritesOff.getOrDefault(websocket, false):
              appState.playerViewers[websocket] = initPlayerViewerState()
            else:
              appState.playerViewers[websocket].resetPlayerViewerStateForRound()
          landSeatTakeoversOnNewMatch()
      if muxState.enabled:
        # Between-games roster reset (multi-trial episodes): mux seats rejoin
        # through the admission loop like websocket seats do.
        muxRequeueJoins()
        for slot in 0 ..< MaxMuxSeats:
          muxViewers[slot] = initPlayerViewerState()

    if not replayLoaded and config.fastMode:
      sockets.resetPlayerReady(playerIndices, sim.players.len)

    var
      spritesOffFlags = newSeq[bool](sockets.len)
      playSocketFlags = newSeq[bool](sockets.len)
    {.gcsafe.}:
      withLock appState.lock:
        for i in 0 ..< sockets.len:
          spritesOffFlags[i] =
            appState.spritesOff.getOrDefault(sockets[i], false)
          playSocketFlags[i] = appState.config.isPlaySeat(
            appState.playerSlots.getOrDefault(sockets[i], -1))
    for i in 0 ..< sockets.len:
      if playSocketFlags[i]:
        continue
      var nextState: PlayerViewerState
      let framePacket = sim.buildSpriteProtocolPlayerUpdates(
        playerIndices[i],
        playerViewerStates[i],
        nextState,
        spritesOff = spritesOffFlags[i]
      )
      {.gcsafe.}:
        withLock appState.lock:
          if sockets[i] in appState.playerViewers:
            appState.playerViewers[sockets[i]] = nextState
      let wirePacket = dedupObjectPlacements(
        if spritesOffFlags[i]: framePacket.stripSpritePixels()
        else: framePacket,
        nextState.sentPlacements
      )
      serverMetrics.recordTraffic(playerIndices[i], wirePacket)
      try:
        if wirePacket.len == 0:
          # One binary message per tick is the frame contract — clients
          # count messages to advance. An all-deduped frame still ships,
          # as an empty message.
          sockets[i].send("", BinaryMessage)
        for chunk in global.chunkSpritePacket(wirePacket, MaxWsFrameBytes):
          sockets[i].send(blobFromBytes(chunk), BinaryMessage)
      except:
        {.gcsafe.}:
          withLock appState.lock:
            discard markSocketClosed(sockets[i])

    # Humans standing in for a seat see exactly what that seat sees — the same
    # fogged view, built from the cog's index. A separate pass, because a
    # takeover socket must never enter `sockets`: that array is the frame's
    # readiness and traffic contract for roster players.
    for i in 0 ..< takeoverSockets.len:
      var nextState: PlayerViewerState
      let framePacket = sim.buildSpriteProtocolPlayerUpdates(
        takeoverCogs[i],
        takeoverStates[i],
        nextState
      )
      {.gcsafe.}:
        withLock appState.lock:
          if takeoverSockets[i] in appState.playerViewers:
            appState.playerViewers[takeoverSockets[i]] = nextState
      let wirePacket = dedupObjectPlacements(
        framePacket,
        nextState.sentPlacements
      )
      try:
        if wirePacket.len == 0:
          takeoverSockets[i].send("", BinaryMessage)
        for chunk in global.chunkSpritePacket(wirePacket, MaxWsFrameBytes):
          takeoverSockets[i].send(blobFromBytes(chunk), BinaryMessage)
      except:
        {.gcsafe.}:
          withLock appState.lock:
            discard markSocketClosed(takeoverSockets[i])
      # Private combat-outcome channel (GameConfig.allowShotFeedback): a
      # SEPARATE TextMessage, never folded into the binary sprite/label wire
      # above, so it can never reach the seat's underlying policy socket —
      # only this takeover pass ever calls buildShotFeedbackPacket. Empty
      # frameShotFeedback (the gate is off, or nothing landed this tick) is
      # the overwhelmingly common case, so this filters and builds only when
      # there is anything to say at all.
      if frameShotFeedback.len > 0:
        var cogShotFeedback: seq[ShotFeedbackFx] = @[]
        for fx in frameShotFeedback:
          if fx.shooterIndex == takeoverCogs[i] or fx.targetIndex == takeoverCogs[i]:
            cogShotFeedback.add fx
        if cogShotFeedback.len > 0:
          let shotFeedbackPacket =
            sim.buildShotFeedbackPacket(cogShotFeedback, takeoverCogs[i])
          if shotFeedbackPacket.len > 0:
            try:
              takeoverSockets[i].send(shotFeedbackPacket, TextMessage)
            except:
              {.gcsafe.}:
                withLock appState.lock:
                  discard markSocketClosed(takeoverSockets[i])
      # Cosmetic-effects channel (GameConfig.allowCosmeticFx): same shape as
      # the shot-feedback block just above — a SEPARATE TextMessage that only
      # this takeover pass ever builds or sends, so it can never reach the
      # seat's underlying policy/mux socket regardless of the gate. The
      # tracer/stain kinds are rebuilt fresh from live sim state every tick
      # (sim.recentShots/sim.paintStains are already fog-clipped inside the
      # builder); the glory kind is different — a one-shot queue like shot
      # feedback, so it IS drained from the per-frame buffer above
      # (frameGloryDeeds) and threaded in here.
      let cosmeticFxPacket =
        sim.buildCosmeticFxPacket(takeoverCogs[i], frameGloryDeeds)
      if cosmeticFxPacket.len > 0:
        try:
          takeoverSockets[i].send(cosmeticFxPacket, TextMessage)
        except:
          {.gcsafe.}:
            withLock appState.lock:
              discard markSocketClosed(takeoverSockets[i])

    if muxConnected():
      # Mux seat frames: the exact wire bytes the websocket path would send
      # (same builder, dedup, and chunking; one record per would-be message,
      # including the empty frame-count message), batched into one write.
      var muxSeatRows: seq[(int, int)] = @[]
      {.gcsafe.}:
        withLock muxState.lock:
          for slot in 0 ..< MaxMuxSeats:
            if muxState.seats[slot].joined:
              muxSeatRows.add((slot, muxState.seats[slot].playerIndex))
      var muxBatch = ""
      for (slot, muxPlayerIndex) in muxSeatRows:
        var nextState: PlayerViewerState
        let framePacket = sim.buildSpriteProtocolPlayerUpdates(
          muxPlayerIndex,
          muxViewers[slot],
          nextState,
          spritesOff = false
        )
        # Stored before dedup mutates nextState.sentPlacements — the same
        # ordering as the websocket loop above, so frames stay byte-identical.
        muxViewers[slot] = nextState
        let wirePacket = dedupObjectPlacements(
          framePacket,
          nextState.sentPlacements
        )
        serverMetrics.recordTraffic(muxPlayerIndex, wirePacket)
        if wirePacket.len == 0:
          muxAppendFrame(muxBatch, slot, [])
        for chunk in global.chunkSpritePacket(wirePacket, MaxWsFrameBytes):
          muxAppendFrame(muxBatch, slot, chunk)
      muxSend(muxBatch)

    for websocket in rewardViewers:
      try:
        websocket.send(rewardPacket, TextMessage)
      except:
        {.gcsafe.}:
          withLock appState.lock:
            discard markSocketClosed(websocket)

    for i in 0 ..< globalViewers.len:
      var nextState: GlobalViewerState
      let packet =
        if replayLoaded:
          sim.buildReplayViewerPacket(
            replayPlayer,
            globalStates[i],
            nextState,
            frameEvents
          )
        else:
          sim.buildLiveViewerPacket(
            globalStates[i],
            nextState,
            liveOverlays,
            sim.tickCount,
            liveProgressMaxTick(config),
            playbackSpeed(liveSpeedIndex),
            replayPlayer.playing,
            replayPlayer.looping,
            frameEvents
          )
      if packet.len == 0:
        continue
      try:
        # The JSON chrome channel rides the SAME binary sprite channel as the
        # board — as the label of a reserved never-drawn 1×1 sprite
        # (BroadcastChromeSpriteId) — because that is the ONLY channel that
        # survives a hosted replay. The legacy opt-in `TextMessage` path never
        # routes the client→server `hud:on` through the recorded stream, so
        # hosted the HUD froze at its DOM defaults while the board played.
        # Piggybacking on the binary channel makes the chrome survive every
        # playback path (live serve, generic client, hosted replay), with no
        # opt-in. The generic bitworld client simply ignores an unknown sprite
        # id. (stakes #7/#9: this channel used to be built ONLY on the
        # `replayLoaded` branch above via buildReplayViewerPacket -- a live
        # match's global viewers got the bare board with no chrome sprite at
        # all, which is why /client/global rendering the rich broadcast HTML
        # was not by itself enough to show the teams-alive bar/end-card;
        # buildLiveViewerPacket now appends the same sprite from live sim
        # state instead of a ReplayPlayer.)
        # Ship in WS-frame-sized chunks at message boundaries: the hosted replay
        # viewer closes any frame over 1 MiB (1009 "message too big"). The client
        # accumulates sprite/object state across binary messages, so N chunks are
        # equivalent to one packet. The init frame (banded map + atlas + chrome)
        # is the only one that ever exceeds the cap; steady-state frames pass
        # through as a single chunk.
        for chunk in global.chunkSpritePacket(packet, MaxWsFrameBytes):
          globalViewers[i].send(blobFromBytes(chunk), BinaryMessage)
        {.gcsafe.}:
          withLock appState.lock:
            if globalViewers[i] in appState.globalViewers:
              # The websocket thread keeps writing viewer INPUT into this table
              # entry while the frame was being built from an earlier snapshot.
              # Blindly storing nextState would erase any input that arrived in
              # between — a seek/command/click landing there was silently lost
              # (scrub-back from the end screen was the visible casualty).
              # Merge: render state comes from nextState, but the latest mouse
              # fields and any not-yet-collected one-shot inputs survive.
              let pending = appState.globalViewers[globalViewers[i]]
              var merged = nextState
              merged.mouseX = pending.mouseX
              merged.mouseY = pending.mouseY
              merged.mouseLayer = pending.mouseLayer
              merged.mouseDown = pending.mouseDown
              if pending.clickPending:
                merged.clickPending = true
              if pending.replaySeekTick >= 0:
                merged.replaySeekTick = pending.replaySeekTick
              if pending.replayCommands.len > 0:
                merged.replayCommands.add(pending.replayCommands)
              if pending.povSelectPending >= -1:
                merged.povSelectPending = pending.povSelectPending
              appState.globalViewers[globalViewers[i]] = merged
      except:
        {.gcsafe.}:
          withLock appState.lock:
            discard markSocketClosed(globalViewers[i])

    if profileShouldDump(sim.gameTicksElapsed()):
      finishAndCopyProfileTrace(profileTraceFinished)

    if quitAfterFrame:
      if squadMode:
        # The `result` control record: the full results document, written once
        # into the replay chat stream at episode end (docs/PROTOCOL.md record
        # table), so a paintball replay is self-sufficient — the outcome would
        # otherwise live only at COGAME_RESULTS_URI, which a spectator with
        # the bytes cannot read. Never applied as a shout at playback (a
        # leading '{' marks a control record in squad mode), so the hash chain
        # is untouched. Classic replays never carry it.
        replayWriter.writeChat(tickTime(sim.tickCount), 0, resultRecord(sim))
      if saveReplayPath.len > 0:
        echo "Writing replay file: ", saveReplayPath
      replayWriter.closeReplayWriter()
      if saveReplayPath.len > 0 and fileExists(saveReplayPath):
        echo "Replay written: ", saveReplayPath,
          " (", getFileSize(saveReplayPath), " bytes)"
        runtimeConfig.writeReplay(readFile(saveReplayPath))
      # STAMP (recut contract Amendment 2 §2): the realized-config stamp,
      # emitted at finalize when its OWN flag is armed (per-flag activation
      # — independent of the recut economy and of every loot flag). Engine-
      # side homes: the events summary row (below) and this log line; the
      # replay header already pins the same facts via the config echo +
      # engineStamp (replay_codec.nim). The episode-attributes API upload is
      # the league-side reporter's job, made from these homes. Dark
      # (stampRealizedConfig=false, every existing config): not a byte of
      # output moves.
      let realizedStamp =
        if sim.config.stampRealizedConfig:
          sim.config.realizedConfigStampJson()
        else:
          ""
      if realizedStamp.len > 0:
        echo "Realized config stamp: ", realizedStamp
      if eventsPath.len > 0:
        # Always written when a sink is configured, even with zero events: the
        # summary row is how a reader tells "this match had none" from "the
        # upload never happened".
        let summaryExtra =
          if realizedStamp.len > 0:
            %*{"realizedConfigStamp": parseJson(realizedStamp)}
          else:
            nil
        writeFile(eventsPath,
          collectedEvents.eventsJsonl(sim.tickCount, summaryExtra))
        echo "Events written: ", eventsPath,
          " (", collectedEvents.len, " events, ", getFileSize(eventsPath), " bytes)"
      # Game-hosted seats: every seat log must be complete before the
      # results marker lands (roles/GAME.md), so stop the children first.
      finishHostedSeats()
      if runtimeConfig.resultsUri.len > 0:
        let scoresJson = sim.playerResultsJson() & "\n"
        runtimeConfig.writeResults(scoresJson)
      elif saveScoresPath.len > 0:
        writeFile(saveScoresPath, sim.playerResultsJson() & "\n")
        echo "Scores written: ", saveScoresPath,
          " (", getFileSize(saveScoresPath), " bytes)"
      block:
        let framesTotal = serverMetrics.frames[SkippedFrame] +
          serverMetrics.frames[WaitedFrame] + serverMetrics.frames[LateFrame]
        proc pct(part: int): string =
          formatFloat(part.float * 100.0 / max(1, framesTotal).float,
            ffDecimal, 1) & "%"
        echo "Frame pacing: ", framesTotal, " playing frames — skipped ",
          serverMetrics.frames[SkippedFrame], " (",
          pct(serverMetrics.frames[SkippedFrame]), "), waited ",
          serverMetrics.frames[WaitedFrame], " (",
          pct(serverMetrics.frames[WaitedFrame]), "), late ",
          serverMetrics.frames[LateFrame], " (",
          pct(serverMetrics.frames[LateFrame]), ")"
        var totalBytes, imageBytes, objectBytes: int64
        for traffic in serverMetrics.players:
          totalBytes += traffic.bytesTotal
          imageBytes += traffic.bytesImage
          objectBytes += traffic.bytesObject
        proc mb(bytes: int64): string =
          formatFloat(bytes.float / 1e6, ffDecimal, 1) & " MB"
        proc share(part: int64): string =
          formatFloat(part.float * 100.0 / max(1'i64, totalBytes).float,
            ffDecimal, 1) & "%"
        echo "Player traffic: ", mb(totalBytes), " to ",
          serverMetrics.players.len, " players — images ", mb(imageBytes),
          " (", share(imageBytes), "), objects ", mb(objectBytes), " (",
          share(objectBytes), ")"
        if metricsPath.len > 0:
          writeFile(metricsPath,
            serverMetrics.metricsJson(sim, sim.tickCount) & "\n")
          echo "Metrics written: ", metricsPath,
            " (", getFileSize(metricsPath), " bytes)"
      if squadMode:
        # Player-facing sockets close NOW, not after the grace window below:
        # a bundled baseline (or human) player only finishes once its
        # connection closes, and the certification runner is waiting on
        # exactly that. Both this tick's final frame and the result record
        # written above are already queued on these sockets, so closing
        # them here loses nothing — see closePlayerSocketsPromptly.
        closePlayerSocketsPromptly(sockets, takeoverSockets)
        # Bounded shutdown grace: the certification runner pings /healthz and
        # /global AFTER the player pods start, and a short squad episode can
        # already have written its artifacts by then. Keep answering for a
        # bounded window, then exit — the runner waits on process exit anyway.
        # Classic games exit immediately, as they always have. Spectators
        # (`globalViewers`) and reward observers stay connected through this
        # whole window untouched, same as before this fix.
        let graceUntil =
          getMonoTime() + initDuration(seconds = ShutdownGraceSeconds)
        while getMonoTime() < graceUntil:
          sleep(200)
      httpServer.close()
      joinThread(serverThread)
      break

    let frameAdvance = runFrameLimiter(
      lastTick,
      not replayLoaded and config.fastMode,
      sockets,
      playerIndices,
      sim.players.len
    )
    # Pacing is only meaningful while a game is actually running: the lobby
    # paces at wall clock by design, and end-card frames idle by design.
    if sim.phase == Playing:
      inc serverMetrics.frames[frameAdvance]
