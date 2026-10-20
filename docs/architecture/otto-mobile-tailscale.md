# Otto Mobile private-network validation

Otto keeps the HTTP host bound to `127.0.0.1`. Tailscale Serve terminates trusted HTTPS and
forwards only tailnet traffic to that loopback service. The pairing QR advertises the HTTPS URL;
the iPhone verifies that endpoint with its newly issued credential before saving anything.

## Configure the private endpoint

1. Install Tailscale on the Mac and iPhone, sign both into the same tailnet, and enable MagicDNS
   and HTTPS for the tailnet.
2. Run `scripts/otto-mobile-tailscale preflight` and confirm the reported node is the intended Mac.
3. Run `scripts/otto-mobile-tailscale configure`.
4. Launch the development app with the exact URL printed by the script:

   ```sh
   OTTO_MOBILE_HOST_PUBLIC_URL=https://your-mac.your-tailnet.ts.net/ \
     scripts/otto-swift run Otto
   ```

5. Run `scripts/otto-mobile-tailscale verify`. It must read `/health` through the tailnet HTTPS
   endpoint, not through loopback.

Do not set `OTTO_MOBILE_HOST_ALLOW_LAN=1` for this route. Direct LAN binding is a separate mode
that requires Otto's own certificate and key. Do not use Tailscale Funnel: this alpha endpoint is
private to the tailnet.

## Two-network Phase 1 exit check

Use a physical iPhone; the simulator does not prove routing or suspension behavior.

1. With the iPhone on the same Wi-Fi as the Mac, scan a fresh pairing code and open Ada.
2. Send a unique message, observe the streamed local-host reply, interrupt one active run, and
   confirm the canonical transcript remains deduplicated after relaunch.
3. Turn Wi-Fi off on the iPhone so it uses cellular while Tailscale remains connected.
4. Reopen Ada, send a second unique message, and observe the streamed reply.
5. Stop the Mac host. Confirm the phone shows `OFFLINE`, retains the cached home/transcript, and
   does not allow a reply to masquerade as sent.
6. Restart the Mac host. Confirm the phone catches up from its durable cursor with no duplicate
   messages.
7. In Otto on the Mac, revoke the iPhone and confirm its next authenticated request is rejected.

Record the iPhone model, iOS version, Mac network, cellular carrier, both message IDs, and the
date. Phase 1 is not accepted until every item passes on both routes.

When testing is finished, `scripts/otto-mobile-tailscale reset` removes the Serve configuration.
