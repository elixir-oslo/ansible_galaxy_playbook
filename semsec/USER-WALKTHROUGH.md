# Walkthrough: the SemSec demo as a user

This walkthrough runs the demo the way a researcher would. You encrypt a file on your own machine, upload it to https://galaxy.semsec.bsc.es, allow Galaxy's jobs to use it, run a tool on it and decrypt the result at home. Your private key never leaves your machine: Galaxy only ever sees encrypted data and a short-lived grant.

Two pieces run on your side: the web browser and the **user service** (`crypt4gh-recryptor-service user`). The user service holds your Crypt4GH key pair. When you click the key icon of a dataset, the browser asks the user service to re-encrypt the dataset's header for Galaxy's compute service. The user service needs to reach that compute service, at `recryptor.semsec.bsc.es`.

The steps below are for Windows with WSL (Ubuntu): the user service runs in WSL, the browser on Windows. WSL passes `localhost` ports through to Windows, so the Windows browser reaches the user service at `https://localhost:61357`. On Linux or macOS, skip the Windows parts.

## 1. Install the user service (WSL)

The service isn't on PyPI, so it's installed from git, at the commit the server runs. It needs `mkcert` to make its own `localhost` certificate.

```
sudo apt update && sudo apt install -y mkcert libnss3-tools
curl -LsSf https://astral.sh/uv/install.sh | sh && source ~/.local/bin/env
uv tool install "git+https://github.com/elixir-europe/crypt4gh-recryptor-service@25ed776"
uv tool install crypt4gh
```

## 2. Configure and start it (WSL)

The service keeps its keys and settings in `c4gh_recryptor_user/` under the directory it starts from. The first start creates your key pair, protected by the passphrase in `.env`, and a `localhost` certificate. `mkcert -install` asks for your sudo password once.

```
mkdir -p ~/semsec && cd ~/semsec
read -rsp "Passphrase for your Crypt4GH key: " P; echo "C4GH_RECRYPTOR_PRIVATE_KEY_PASSPHRASE=$P" > .env; chmod 600 .env; unset P
export C4GH_RECRYPTOR_COMPUTE_HOST=recryptor.semsec.bsc.es C4GH_RECRYPTOR_COMPUTE_PORT=8443
crypt4gh-recryptor-service user
```

Leave it running in this window. In a second WSL window, check it answers:

```
curl -sS https://localhost:61357/info
```

## 3. Let the Windows browser trust the user service

The browser only talks to the user service if it trusts its certificate. That certificate comes from the mkcert certificate authority inside WSL, so add that authority to Windows. In WSL:

```
cp "$(mkcert -CAROOT)/rootCA.pem" /mnt/c/Users/Public/wsl-mkcert-rootCA.crt
```

Then in Windows PowerShell (no admin rights needed):

```
certutil -user -addstore Root C:\Users\Public\wsl-mkcert-rootCA.crt
```

Restart the browser and open https://localhost:61357/info. It should show the service's name without a certificate warning. Edge and Chrome use the Windows store. Firefox needs `security.enterprise_roots.enabled` set to `true` in `about:config`.

## 4. Make an encrypted test file (WSL)

```
cd ~/semsec
printf "@r1\nACGTACGT\n+\nIIIIIIII\n" > reads.fastq
crypt4gh encrypt --recipient_pk c4gh_recryptor_user/user_keys/user_key.pub < reads.fastq > reads.fastqsanger.c4gh
cp reads.fastqsanger.c4gh /mnt/c/Users/Public/
```

## 5. Set up storage in Galaxy

Log in to https://galaxy.semsec.bsc.es. Protected jobs need the history on your own S3 storage, so the encrypted outputs go straight from the compute host to your bucket.

1. User, Preferences, Manage Your Galaxy Storage: create a storage from "Any S3 Compatible Storage" with endpoint `http://semsec-galaxy:8443`, bucket `galaxy-c4gh`, and the demo access key and secret key (ask the admin).
2. Create a new history. Click the storage icon under its title and select the storage you just made.

## 6. Upload, authorize and run

1. Upload `C:\Users\Public\reads.fastqsanger.c4gh`. Galaxy detects the encryption and gives it the type `fastqsanger.c4gh`.
2. Expand the dataset and click the key icon. The browser asks your user service, and the dataset shows as authorized, with an expiry date.
3. Run "Concatenate datasets" (`cat1`) on it. The job runs on the separate Pulsar host and its output is encrypted for you.

## 7. Download and decrypt (WSL)

Download the output from Galaxy (the disk icon) to `C:\Users\Public\`, then:

```
cd ~/semsec
crypt4gh decrypt --sk c4gh_recryptor_user/user_keys/user_key.priv < /mnt/c/Users/Public/<downloaded file> 
```

It asks for your passphrase and prints the same four lines as `reads.fastq`.

## If the key icon fails

- "Could not reach the user service": the service in step 2 isn't running, or the browser doesn't trust its certificate (step 3).
- An error mentioning the compute service: the user service can't reach `recryptor.semsec.bsc.es:8443`. Check with `curl -sS https://recryptor.semsec.bsc.es:8443/info` in WSL.
