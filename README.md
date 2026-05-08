# IPv6 Optimizer

Got a whole /64 IPv6 subnet but not sure which IP is the fastest? This script does the heavy lifting for you. 

It randomly picks IPs from your subnet, pings your target address, and ranks the top 10 fastest ones. Think of it like picking the best apples from a huge basket. 

### Why use this?
* **It's fast.** It tests many IPs at the same time. 
* **It's clean.** The script cleans up after itself. It removes all the temporary test IPs when it finishes, keeping your network card tidy.
* **It's visual.** You get a nice progress bar to see how things are going.

### What you need
* A Linux server with a working IPv6 network.
* Root access (or a user with `sudo` rights).
* `ping` or `ping6` installed.

### How to run it
Just download the script, make it executable, and run it. The script will ask you for the target IP and how many IPs you want to test.

```bash
wget [https://raw.githubusercontent.com/your-username/your-repo/main/ipv6_pre.sh](https://raw.githubusercontent.com/your-username/your-repo/main/ipv6_pre.sh)
chmod +x ipv6_pre.sh
sudo ./ipv6_pre.sh
