--[[
    tests/bodyclaims_spec.lua

    Direct tests of server/bodyclaims.lua's own three resource-globals
    (ClaimBody/ReleaseBody/IsBodyClaimedByOther) against the REAL,
    unmodified production file, in isolation. Same overall shape as
    tests/entities_spec.lua's own CROSS-FEATURE NETID CLAIM REGISTRY
    section (ClaimNetworkEntity/ReleaseNetworkEntity/
    IsNetworkEntityClaimedByOther) — this file is that same pattern applied
    to a citizenid instead of a netId; read that section's own header
    comment first if this one is unclear.

    THE RED-THEN-GREEN PROOF this file exists to carry, per the task that
    scoped this pass:
      1. RED, closed: a second, DIFFERENT mechanic's claim on the SAME
         citizenid while a first is still live is REFUSED — see "ClaimBody:
         a DIFFERENT mechanic cannot claim a citizenid already live-claimed
         by another" below. This is the exact shape of the confirmed
         kennel-vs-vehicle-seat race, reduced to this file's own primitives
         with no kennel/vehicle-specific machinery needed to prove it.
      2. GREEN, the control: an ordinary single claim (no prior claim held)
         still succeeds every time — see "ClaimBody: an unclaimed
         citizenid can always be claimed" below. A fix that refused
         EVERYTHING would pass proof 1 above trivially and be
         catastrophic; this is the assertion that would catch that.
      3. GREEN, the other control: releasing (the "stop" path) works
         correctly WHILE a claim is actively held, and remains a safe no-op
         when it is not — see the ReleaseBody section below, including the
         "never lets a stranger release someone else's claim" case, which
         is this file's own version of the "never gate a termination path"
         rule applied to a WRONG caller rather than a right one.
    The actual CROSS-FILE integration — proving server/kennel.lua's
    requestEnterKennel, server/vehicle.lua's requestVehicleSeatClaim, and
    server/combat.lua's ValidateCombatRequest genuinely consult this SAME
    registry instance and correctly refuse a real cross-mechanic race — is
    covered in each of those three files' own specs (kennel_spec.lua's,
    vehicle_spec.lua's, and combat_spec.lua's own EXCLUSIVE BODY-CLAIM
    REGISTRY sections), not duplicated here; this file only proves the
    three primitives' own, file-local contract in isolation — mirroring
    entities_spec.lua's own explicit split for the identical reason.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ----------------------------------------------------------------------
-- Sandbox setup — a real, steppable GetGameTimer (needed for TTL/expiry),
-- and a real thread runner (needed for the periodic-sweep-exists proof).
-- Mirrors server/vehicle.lua's own tests/vehicle_spec.lua fixture shape.
-- ----------------------------------------------------------------------

local fakeNow = 0
local function GetGameTimer() return fakeNow end

local printedLines = {}
local function printStub(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
    printedLines[#printedLines + 1] = table.concat(parts, '\t')
end

local runner = Sandbox.newThreadRunner()
local threadCreateCount = 0
local function CreateThread(fn)
    threadCreateCount = threadCreateCount + 1
    runner.CreateThread(fn)
end

local env = Sandbox.newEnv({
    GetGameTimer = GetGameTimer,
    CreateThread = CreateThread,
    Wait = runner.Wait,
    print = printStub,
})

Sandbox.loadInto('../server/bodyclaims.lua', env)

local ClaimBody = env.ClaimBody
local ReleaseBody = env.ReleaseBody
local IsBodyClaimedByOther = env.IsBodyClaimedByOther

t.isNotNil(ClaimBody, 'server/bodyclaims.lua must define global ClaimBody')
t.isNotNil(ReleaseBody, 'server/bodyclaims.lua must define global ReleaseBody')
t.isNotNil(IsBodyClaimedByOther, 'server/bodyclaims.lua must define global IsBodyClaimedByOther')

-- ----------------------------------------------------------------------
-- BodyClaims itself is one shared table for this entire loaded env (not
-- reset between tests, same as entities_spec.lua's own ClaimedNetworkEntities
-- note) -- every test below uses its own distinct citizenid so no test can
-- observe another's claims.
-- ----------------------------------------------------------------------

t.test('IsBodyClaimedByOther: an unclaimed citizenid is never claimed by anyone', function()
    t.isFalse(IsBodyClaimedByOther('CIT_0001', 'kennel_rest'))
end)

t.test('ClaimBody: an unclaimed citizenid can always be claimed -- THE CONTROL: an ordinary single claim must succeed', function()
    t.isTrue(ClaimBody('CIT_0002', 'kennel_rest'))
    t.isFalse(IsBodyClaimedByOther('CIT_0002', 'kennel_rest'), 'the claimant itself never collides with its own claim')
    t.isTrue(IsBodyClaimedByOther('CIT_0002', 'vehicle_seat'), 'a DIFFERENT mechanic correctly sees this citizenid as claimed')
end)

t.test('ClaimBody: re-claiming for the SAME mechanic is a RENEWAL, not a collision, and always succeeds', function()
    t.isTrue(ClaimBody('CIT_0003', 'vehicle_seat', 1000))
    t.isTrue(ClaimBody('CIT_0003', 'vehicle_seat', 1000), 'the same mechanic re-confirming its own prior claim must never be refused')
end)

t.test('ClaimBody: a DIFFERENT mechanic cannot claim a citizenid already live-claimed by another -- THE RACE THIS FILE CLOSES', function()
    t.isTrue(ClaimBody('CIT_0004', 'kennel_rest'))
    t.isFalse(ClaimBody('CIT_0004', 'vehicle_seat', 10000), 'a second, different exclusive mechanic must be refused while the first claim is still live')
    -- and the ORIGINAL claim must still stand, untouched by the refused attempt
    t.isFalse(IsBodyClaimedByOther('CIT_0004', 'kennel_rest'), 'the original claimant is unaffected by the refused collision')
end)

t.test('IsBodyClaimedByOther: names WHICH mechanic holds the claim, for a denying caller to pick an accurate message', function()
    ClaimBody('CIT_0005', 'combat_target', 5000, 'drag')
    local claimed, otherMechanic, detail = IsBodyClaimedByOther('CIT_0005', 'vehicle_seat')
    t.isTrue(claimed)
    t.equals(otherMechanic, 'combat_target')
    t.equals(detail, 'drag')
end)

t.test('IsBodyClaimedByOther: detail is nil when the claiming call never supplied one', function()
    ClaimBody('CIT_0006', 'kennel_rest')
    local claimed, otherMechanic, detail = IsBodyClaimedByOther('CIT_0006', 'vehicle_seat')
    t.isTrue(claimed)
    t.equals(otherMechanic, 'kennel_rest')
    t.isNil(detail)
end)

-- ----------------------------------------------------------------------
-- ReleaseBody
-- ----------------------------------------------------------------------

t.test('ReleaseBody: clears a claim when the mechanic matches exactly -- releasing while a claim is held works, and frees the citizenid for a different mechanic', function()
    ClaimBody('CIT_0007', 'kennel_rest')
    ReleaseBody('CIT_0007', 'kennel_rest')
    t.isFalse(IsBodyClaimedByOther('CIT_0007', 'vehicle_seat'), 'unclaimed after release -- no longer collides with anyone')
    t.isTrue(ClaimBody('CIT_0007', 'vehicle_seat', 10000), 'a DIFFERENT mechanic can now claim the same citizenid, exactly the control this whole registry exists to preserve')
end)

t.test('ReleaseBody: does NOT clear a claim when the mechanic does not match -- fails closed, never lets a stranger release someone else\'s claim', function()
    ClaimBody('CIT_0008', 'kennel_rest')
    ReleaseBody('CIT_0008', 'vehicle_seat') -- wrong mechanic
    t.isTrue(IsBodyClaimedByOther('CIT_0008', 'vehicle_seat'), 'the real claim must still stand')
    t.isFalse(IsBodyClaimedByOther('CIT_0008', 'kennel_rest'), 'and the real claimant still recognizes it as its own')
end)

t.test('ReleaseBody: a no-op on a citizenid that was never claimed at all -- never errors', function()
    ReleaseBody('CIT_0009', 'kennel_rest')
    t.isFalse(IsBodyClaimedByOther('CIT_0009', 'vehicle_seat'))
end)

t.test('ReleaseBody: never gates on anything -- callable at any time, mirrors this resource\'s "never gate a termination path" rule', function()
    ClaimBody('CIT_0010', 'combat_target', 5000, 'bite')
    ReleaseBody('CIT_0010', 'combat_target')
    ReleaseBody('CIT_0010', 'combat_target') -- calling it again after it's already gone must still be a safe no-op
    t.isFalse(IsBodyClaimedByOther('CIT_0010', 'vehicle_seat'))
end)

-- ----------------------------------------------------------------------
-- Malformed input -- defensive, never trust a caller's own bug into a bad write
-- ----------------------------------------------------------------------

t.test('ClaimBody: a nil citizenid is a silent no-op / always false, never an error', function()
    t.isFalse(ClaimBody(nil, 'kennel_rest'))
end)

t.test('ClaimBody: an empty-string citizenid is a silent no-op / always false, never an error', function()
    t.isFalse(ClaimBody('', 'kennel_rest'))
end)

t.test('ClaimBody: a non-string citizenid (a raw server id number, the exact mistake this file\'s own header warns against) is a silent no-op', function()
    t.isFalse(ClaimBody(42, 'kennel_rest'), 'server ids are recycled -- this registry must only ever accept a durable citizenid')
end)

t.test('ReleaseBody/IsBodyClaimedByOther: a non-string citizenid never errors and never reports a claim', function()
    ReleaseBody(42, 'kennel_rest') -- must not error
    t.isFalse(IsBodyClaimedByOther(42, 'vehicle_seat'))
end)

-- ----------------------------------------------------------------------
-- EXPIRY POLICY: a supplied ttlMs bounds the claim; omitting it (nil) means
-- permanent -- see server/bodyclaims.lua's own header for the full
-- 'kennel_rest' reasoning this locks in.
-- ----------------------------------------------------------------------

t.test('ClaimBody with a ttlMs: still live just before expiry', function()
    fakeNow = 0
    ClaimBody('CIT_0011', 'combat_target', 1000, 'takedown')
    fakeNow = 999
    t.isTrue(IsBodyClaimedByOther('CIT_0011', 'vehicle_seat'), 'must still be live at 999ms of a 1000ms claim')
end)

t.test('ClaimBody with a ttlMs: lazily expires the instant it is read past its own expiresAt, freeing the citizenid for a different mechanic', function()
    fakeNow = 0
    ClaimBody('CIT_0012', 'combat_target', 1000, 'takedown')
    fakeNow = 1001
    t.isFalse(IsBodyClaimedByOther('CIT_0012', 'vehicle_seat'), 'an expired claim must never be reported as live')
    t.isTrue(ClaimBody('CIT_0012', 'vehicle_seat', 10000), 'a DIFFERENT mechanic must be able to claim it once the old one has genuinely expired -- a 300ms race must never become a permanent lockout')
end)

t.test('ClaimBody with NO ttlMs (omitted -- the kennel_rest shape): NEVER expires by time alone, no matter how far the clock advances', function()
    fakeNow = 0
    ClaimBody('CIT_0013', 'kennel_rest')
    fakeNow = 24 * 60 * 60 * 1000 -- 24 real hours later
    t.isTrue(IsBodyClaimedByOther('CIT_0013', 'vehicle_seat'), 'a permanent claim (no ttlMs) must still be live -- kennel-rest legitimately has no natural time limit')
    -- Only an explicit ReleaseBody call ends it -- exactly the same
    -- "explicit release, not a timer" discipline server/kennel.lua's own
    -- KennelOccupants registry already relies on.
    ReleaseBody('CIT_0013', 'kennel_rest')
    t.isFalse(IsBodyClaimedByOther('CIT_0013', 'vehicle_seat'))
end)

t.test('CLAMP-AND-WARN: a non-positive ttlMs is clamped to a safe fallback, never a bare crash', function()
    fakeNow = 0
    local before = #printedLines
    local ok = ClaimBody('CIT_0014', 'vehicle_seat', 0)
    t.isTrue(ok, 'a bad ttlMs must degrade the claim to a safe bound, never abort the calling handler')
    t.isTrue(#printedLines > before, 'a clamp must be logged, not silently swallowed')
    -- Still bounded (not accidentally made permanent) -- advancing well past
    -- BODY_CLAIM_FALLBACK_TTL_MS (15000, per that file's own declared
    -- constant) must eventually free it.
    fakeNow = 20000
    t.isFalse(IsBodyClaimedByOther('CIT_0014', 'kennel_rest'), 'the clamped fallback TTL must still be a REAL bound, not an accidental permanent claim')
end)

t.test('CLAMP-AND-WARN: a negative ttlMs is likewise clamped, never a bare crash', function()
    fakeNow = 0
    t.isTrue(ClaimBody('CIT_0015', 'vehicle_seat', -500))
end)

t.test('CLAMP-AND-WARN: a non-number ttlMs is likewise clamped, never a bare crash', function()
    fakeNow = 0
    t.isTrue(ClaimBody('CIT_0016', 'vehicle_seat', 'soon'))
end)

-- ----------------------------------------------------------------------
-- PERIODIC SWEEP -- "a way to expire" must not depend solely on some future
-- caller happening to touch this exact citizenid again (mirrors
-- server/vehicle.lua's own VEHICLE_SEAT_CLAIM_SWEEP_INTERVAL_MS mechanism
-- 4). The deeper behavioral guarantee (a stale claim never blocks forever)
-- is already locked in by the lazy-expiry test above -- both mechanisms
-- share the identical `expiresAt` condition, so this test only needs to
-- confirm the sweep thread itself exists and is started UNCONDITIONALLY at
-- file load, mirroring server/vehicle.lua's own "LIVE-FLIP FIX" test shape.
-- ----------------------------------------------------------------------

t.test('the periodic sweep thread is created unconditionally at file load', function()
    t.equals(threadCreateCount, 1, 'server/bodyclaims.lua has no feature flag of its own to gate this on -- it must always start')
end)

os.exit(t.summary())
