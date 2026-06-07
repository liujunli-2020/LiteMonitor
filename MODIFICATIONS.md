# LiteMonitor fork modifications

This repository is forked from https://github.com/Diorser/LiteMonitor.

Base verified source:

- Upstream: `Diorser/LiteMonitor`
- Version: `1.3.6`
- Commit used locally: `169e90a build: bump version to 1.3.6`

## Changes

- Added taskbar left-click manual plugin refresh.
  - Clicking the taskbar monitor area now refreshes enabled visible plugin instances immediately.
  - Manual refresh is throttled to avoid repeated network requests from accidental rapid clicks.

- Replaced the application icon with a monochrome TrafficMonitor-style icon.
  - The icon is generated from the local TrafficMonitor logo reference.
  - The generated ICO contains multiple sizes for clearer tray/taskbar rendering.

- Updated `PublicIP` plugin.
  - Uses `https://api.ipify.org?format=json` instead of `whois.pconline.com.cn`.
  - Adds configurable proxy input, defaulting to the verified local proxy `127.0.0.1:10808`.
  - The displayed label is changed to `出口IP` to make it clear that the value is the current egress IPv4.

- Updated `ProxyLatency` defaults.
  - Default local proxy address changed to `127.0.0.1:10808`.

- Added LiteMonitor bridge plugins migrated from TrafficMonitor plugins.
  - `LiteMonitor_SubTraffic.json`: subscription traffic usage and expiry.
  - `LiteMonitor_VpsTraffic.json`: VPS network rates, BandwagonHost traffic usage/reset, TCP counts.
  - `resources/plugins/LiteMonitorBridge`: local PowerShell bridge service used by those plugins.

## Local verification notes

- `127.0.0.1:10808` was verified through the LiteMonitor-compatible proxy path against `http://www.gstatic.com/generate_204`.
- Public IP tests showed different values by endpoint:
  - `api.ipify.org`, `ipinfo.io`, and `ifconfig.co`: `199.19.108.252`
  - `whois.pconline.com.cn`: `1.203.116.230`
  - `myip.ipip.net`: IPv6 `240e:305:a9c:700:8d2b:eedf:9262:4165`
- Because `whois.pconline.com.cn` reports the direct domestic IPv4 path while global APIs report the current egress IPv4, this fork uses `api.ipify.org` for the taskbar public IP display.
