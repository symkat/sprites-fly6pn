# Sprites Fly6PN

Connect your Sprite to your Fly 6PN Network.

## SYNOPSIS

Sprites Fly6PN joins a Sprite to your Fly Organization's 6PN network to access `.flycast`, `.internal`, and `.flympg.net`.


Once setup, you can access all Fly Cast Services through `.flycast`, Fly Machines through the `.internal` network and `flympg.net` MPG hosts.  Your Fly Machines can access the sprite on `<sprite_name>._peer.internal`.

The installer registers the Sprite as a WireGuard peer on your Fly.io org using the Fly GraphQL API, then runs a userspace WireGuard tunnel (wireguard-go).  A second service runs dnsmasq as a split DNS resolver: it sends `.internal`, `.flycast` and `flympg.net` lookups through the tunnel to the org's DNS server and everything else to the Sprite's normal resolver, so Fly apps, Flycast addresses and Managed Postgres resolve by name while ordinary DNS keeps working.


## INSTALLATION

### 1. Create the wireguard token

Run `fly tokens create wireguard -x30m` and select the organization you'd like the Sprite to access.  This token will automatically expire in 30 minutes.

You'll need the full token (`FlyV1 fm2_...`) in the next step.

Tip: You can pass an org name with `fly tokens create wireguard -x30m --org <org_name>` to avoid the interactive organization selector.

### 2. Give the Sprite access to the wireguard token

You can choose between two methods.  Either set the token as an environment variable, `FLY_API_TOKEN` or add it as a connector and the Sprite will never see the token.

Option 1: 

```
export FLY_API_TOKEN="FlyV1 fm2_..."
```

Option 2:

1.  Open your Dashboard at https://fly.io/dashboard/
2.  Click `Sprites` in the left hand navigation menu.
3.  Click `Connectors` in navigation menu towards the top of the panel.
4.  Click the `Add Connector` button.
5.  Enter `Custom` into the search panel.
6.  Click `Custom API` from the results.
7.  Enter the details:
  * Base API URL: https://api.fly.io
  * Connection name: API (WireGuard)
  * Description: Connector to setup Sprites-Fly6PN
  * Access token: \<The Token You Generated\>
8. Click `Save Anyway`
9. You should now be on the list of enabled connectors.  Click `API (WireGuard)`.
10.  Enter the name of the Sprite you want to setup into `Name Prefix`, or click `Allow All Sprites`.
11. Click `Save`.

### 3. Run the installer

From the sprite, run the installer:

```
curlhttps://raw.githubusercontent.com/symkat/sprites-fly6pn/refs/heads/main/install.sh | bash
```

If you are using a Sprite Connector for the credentials you'll get a prompt like:

```
Use Sprite connector 'API (WireGuard)' (xxxxxxx-xxxxxxxxx) to join Fly.io org '<Your Org Name>'? [Y/n] Y
```

Press Y.

Once the installation completes and you're connected, you'll get information about the connection:

```
==> Installing packages: wireguard-go wireguard-tools dnsmasq-base
==> Using FLY_API_TOKEN from the environment
==> Detected org: <Your Org Name>
==> Using nearest region: iad
==> Creating WireGuard peer <Your Sprite Name> in <Your Org> (iad)
==> Creating Sprite service fly6pn
==> Creating Sprite service fly6pn-dns
==> Waiting for the WireGuard handshake

sprite-fly6pn is up.
  org:          <Your Org Name>
  peer:         sprite-<Your Sprite Name> (iad)
  6PN address:  fdaa:e7:fbe4:....
  org DNS:      fdaa:e7:fbe4::3
  services:     fly6pn, fly6pn-dns

From this Sprite:
  dig +short txt _apps.internal          # apps in the org
  curl http://<app>.flycast/             # Flycast (through fly-proxy)
  curl http://<app>.internal:<port>/     # straight to Machines over 6PN

From a Fly Machine in shiny-sprites, this Sprite is:
  sprite-<Your Sprite Name>._peer.internal  ->  fdaa:e7:fbe4:....
  (the Sprite must be awake; see README "Reaching the Sprite from Fly Machines")

```

### Operations

**Restart Tunnel**

```
sprite-env services restart fly6pn
```

**Tunnel Details**

```
sudo wg show fly0
```

**Check Status**

```
curl https://raw.githubusercontent.com/symkat/sprites-fly6pn/refs/heads/main/install.sh | bash -s -- status
```

**Uninstall**

```
curl https://raw.githubusercontent.com/symkat/sprites-fly6pn/refs/heads/main/install.sh | bash -s -- status
```

### AVAILABILITY 

The latest code can be found at https://github.com/symkat/sprites-fly6pn
