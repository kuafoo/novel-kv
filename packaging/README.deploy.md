# NovelKV Deployment Guide

## Quick Install

```bash
tar xzf novelkv-VERSION-linux-x86_64.tar.gz
cd novelkv-VERSION-linux-x86_64
sudo ./install.sh
```

## Configuration

Edit `/etc/novelkv/novelkv.conf` before starting in production.

At minimum, set a strong password:
```
NOVELKV_OPTS="--host 0.0.0.0 --port 6379 --data /var/lib/novelkv --log-level info --disable-dangerous --requirepass YOUR_PASSWORD"
```

Then restart: `sudo systemctl restart novelkv`

## Service Management

```bash
sudo systemctl start novelkv     # Start
sudo systemctl stop novelkv      # Stop
sudo systemctl restart novelkv   # Restart
sudo systemctl status novelkv    # Status
sudo journalctl -u novelkv -f    # View logs
```

## Connect

NovelKV is compatible with the Redis protocol (RESP). Use any Redis client:

```bash
redis-cli -p 6379 -a YOUR_PASSWORD
redis-cli -p 6379 -a YOUR_PASSWORD PING
```

## Replica Setup

On the replica machine:

1. Install NovelKV
2. Edit `/etc/novelkv/novelkv.conf`:
   ```
   NOVELKV_OPTS="--host 0.0.0.0 --port 6379 --data /var/lib/novelkv --log-level info --replicaof MASTER_HOST 6379 --masterauth MASTER_PASSWORD"
   ```
3. Start: `sudo systemctl start novelkv`

## TLS Setup

1. Place certificates in `/etc/novelkv/certs/`:
   ```bash
   sudo mkdir -p /etc/novelkv/certs
   sudo cp server.pem server-key.pem ca.pem /etc/novelkv/certs/
   sudo chown -R novelkv:novelkv /etc/novelkv/certs
   sudo chmod 600 /etc/novelkv/certs/server-key.pem
   ```
2. Update `novelkv.conf` with `--tls-cert`, `--tls-key`, `--tls-ca` flags
3. Restart: `sudo systemctl restart novelkv`
4. Connect: `redis-cli --tls --cert ... -p 6379`

## Data Location

- Data:     `/var/lib/novelkv/`
- Config:   `/etc/novelkv/novelkv.conf`
- Logs:     `journalctl -u novelkv`

## Uninstall

```bash
sudo ./uninstall.sh          # Keep data
sudo ./uninstall.sh --purge  # Remove everything
```

## Upgrade

1. Build/download new package
2. Run `sudo ./install.sh` (stops service, replaces binary, starts service)
3. Data is preserved across upgrades
