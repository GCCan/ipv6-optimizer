# IPv6 Optimizer

Got a massive `/64` IPv6 subnet but not sure which specific IP gives you the lowest latency? This script does the heavy lifting for you.

It automatically generates random IPv6 addresses within your subnet, tests their ping against a target of your choice, and ranks the top 10 fastest ones. 

## ✨ Features
* **Smart Pre-flight Check:** It pings the target with your main IP first to ensure the network is actually connected before doing the hard work.
* **Fast & Concurrent:** Pings multiple IPs at the same time to get results quickly.
* **Auto Cleanup:** It completely cleans up after itself. All temporary IPs are automatically removed from your network interface once the script finishes or if you cancel it early.
* **Clean UI:** Includes a smooth terminal progress bar.

## 🚀 How to Use

1. Download the script to your server.
2. Make it executable.
3. Run it!

```bash
wget [https://raw.githubusercontent.com/your-username/ipv6-optimizer/main/ipv6_pre.sh](https://raw.githubusercontent.com/your-username/ipv6-optimizer/main/ipv6_pre.sh)
chmod +x ipv6_pre.sh
sudo ./ipv6_pre.sh
