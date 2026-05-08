# IPv6 Optimizer

Do you have a big IPv6 subnet? Want to find the fastest IP? This script does exactly that. 

It finds your real subnet size first, like /64, /80, or /112. Then, it tests random IPs to find the one with the lowest ping.

### ✨ Features
* **Smart Subnet Check:** It uses Python to find your exact subnet mask. 
* **Quick Network Test:** It tests your main IP first. If your network is down, it tells you right away so you don't waste time.
* **Really Fast:** It tests many IPs at the same time.
* **Cleans Up:** It deletes all temporary test IPs when it finishes. Your server stays clean.

### 🛠️ What You Need
* A Linux server with IPv6.
* Root access (or `sudo`).
* `python3` (to read the IP correctly).
* `ping` or `ping6`.

### 🚀 How to Run It

Download the script, make it runnable, and start it:

```bash
wget [https://raw.githubusercontent.com/your-username/ipv6-optimizer/main/ipv6_pre.sh](https://raw.githubusercontent.com/your-username/ipv6-optimizer/main/ipv6_pre.sh)
chmod +x ipv6_pre.sh
sudo ./ipv6_pre.sh
