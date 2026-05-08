# IPv6 Optimizer

Quickly test and rank random IPv6 addresses in your subnet to find the lowest ping. 

If you have a big IPv6 subnet, this script helps you find the fastest IP. It finds your real subnet size first, like /64, /80, or /112. Then, it tests random IPs to find the best one.

### ✨ Features
* **Smart Subnet Check:** It uses Python to find your exact subnet mask. 
* **Quick Network Test:** It tests your main IP first. If your network is down, it tells you right away. 
* **Really Fast:** It tests many IPs at the same time.
* **Cleans Up:** It deletes all temporary test IPs when it finishes. Your server stays clean.

### 🛠️ What You Need
* A Linux server with IPv6.
* Root access (or `sudo`).
* `python3` (to read the IP correctly).
* `ping` or `ping6`.

### 🚀 How to Run It

Download the script, make it runnable, and start it. Just copy and paste this:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/GCCan/ipv6-optimizer/refs/heads/main/v6_opt.sh)
