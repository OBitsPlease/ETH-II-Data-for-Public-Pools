# ETH II Node Runtime

Docs and service templates for running ETH II peers and public pool nodes.

## Where are the downloads?

Node and stratum binaries are **no longer published on GitHub**. They are distributed through the official gated download service with a personal access key:

- Request a key by opening an issue on this repo titled `Key request` (include a short note about how you plan to run the node), or via the contact info on https://www.ethii.net
- Once you have a key, download from:
  - `https://www.ethii.net/dl/ethii-linux-amd64?key=YOUR-KEY`
  - `https://www.ethii.net/dl/ethii-windows-amd64.exe?key=YOUR-KEY`
  - `https://www.ethii.net/dl/stratum-linux-amd64?key=YOUR-KEY`
  - `https://www.ethii.net/dl/stratum-windows-amd64.exe?key=YOUR-KEY`

Keys are individually issued and can be revoked. Do not share your key.

## Chain identity (verify before connecting)

- Network ID (`--networkid`): `20482`
- Chain ID: `2048`
- Genesis hash: `0x6836fa7f7ddaf5807ff48b4eb9f4fd63ceaf33d52ae419349bd72b85dd34f8bf`
- Block time: ~10 seconds, block reward: 5 ETHII (fixed)

If your node reports a different genesis hash you are on the wrong chain — wipe the datadir and re-init with the `genesis.json` from this repo.

## Seed peers (static-nodes.json)

```
enode://05f7f1c669368d16829699b6e1ddffbd8a3fee08a1301cac33922ad05f56fd53aadbca02f326d6b1c863c560c9adf30a75b44d45e7448ebb41d9c47235204fdf@87.99.142.128:30303
enode://b096bfae7d5e9a7cc985e68726280b75b0a0ef80ce419db5ed5152e9bee7bf83d35ae8b13b34879a0bf36d73a9a674bb61b02f3777745ed770e3150a39c7de5b@91.99.231.217:30303
```

## Quick start

Windows:
- Download `ethii-windows-amd64.exe` with your key (see above).
- Put it next to `genesis.json` and the scripts from `deploy/windows/`.
- Double-click `START-HERE.bat`.

Linux:
- Download `ethii-linux-amd64` with your key (see above).
- Copy `genesis.json` and the files in `deploy/linux/` to the target host.
- Install `deploy/linux/ethii-node.service` for a mining/pool host.
- Install `deploy/linux/ethii-relay-node.service` for a non-mining relay host.

## Included files

- `genesis.json`
- `suite-version.txt`
- `static-nodes.json`
- `deploy/linux/config.toml`
- `deploy/linux/ethii-node.service`
- `deploy/linux/ethii-relay-node.service`
- `deploy/linux/start-miner.sh`
- `deploy/windows/START-HERE.bat`
- `deploy/windows/one-click-relay.bat`
- `deploy/windows/setup-relay-node.ps1`
- `deploy/windows/check-node-health.ps1`
- `deploy/windows/run-health-check.bat`

## Ports

- 30303 TCP + UDP: node P2P
- 3335 TCP: standard pool stratum
- 3336 TCP: A10/ASIC stratum
- 8082 TCP: dashboard

## Pool

Public pool at `stratum+tcp://91.99.231.217:3335` (PPLNS by default; prefix your address with `solo:` to solo mine).
