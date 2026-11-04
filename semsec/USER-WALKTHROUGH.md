# Walkthrough: the SemSec demo as a user

This walkthrough runs the demo the way a researcher would. You encrypt a file on your own machine, upload it to https://galaxy.semsec.bsc.es, allow Galaxy's jobs to use it, run a tool on it and decrypt the result at home. Step 7 then does the same with a file from the European Genome-phenome Archive (EGA). Your private key never leaves your machine: Galaxy only ever sees encrypted data and a short-lived grant.

Two pieces run on your side: the web browser and the **user service** (`crypt4gh-recryptor-service user`). The user service holds your Crypt4GH key pair. When you click the key icon of a dataset, the browser asks the user service to re-encrypt the dataset's header for Galaxy's compute service. The user service needs to reach that compute service, at `recryptor.semsec.bsc.es`.

Steps 1 to 4 and 8 run on your machine and differ per system. Steps 5 to 7 are in Galaxy and on the EGA website, and are the same for everyone.

- **Windows:** the user service runs in WSL (Windows Subsystem for Linux, Ubuntu), the browser on Windows. WSL passes `localhost` ports through to Windows, so the browser reaches the user service at `https://localhost:61357`.
- **macOS and Linux:** everything runs directly on your machine.

## 1. Install the user service

The service isn't on PyPI, so it's installed from git, at the commit the server runs. It needs `mkcert` to make its own `localhost` certificate, and `uv` to install Python tools.

### Windows

In an Ubuntu (WSL) window:

```
sudo apt update && sudo apt install -y mkcert libnss3-tools
curl -LsSf https://astral.sh/uv/install.sh | sh && source ~/.local/bin/env
uv tool install "git+https://github.com/elixir-europe/crypt4gh-recryptor-service@25ed776"
uv tool install crypt4gh
```

### macOS

With [Homebrew](https://brew.sh):

```
brew install mkcert nss uv
uv tool install "git+https://github.com/elixir-europe/crypt4gh-recryptor-service@25ed776"
uv tool install crypt4gh
```

### Linux

On Debian or Ubuntu (other distributions have `mkcert` and the NSS tools under similar names):

```
sudo apt update && sudo apt install -y mkcert libnss3-tools
curl -LsSf https://astral.sh/uv/install.sh | sh && source ~/.local/bin/env
uv tool install "git+https://github.com/elixir-europe/crypt4gh-recryptor-service@25ed776"
uv tool install crypt4gh
```

## 2. Configure and start it

This is the same on all systems; on Windows, run it in the Ubuntu (WSL) window.

The service keeps its keys and settings in `c4gh_recryptor_user/` under the directory it starts from. The first start creates your key pair, protected by the passphrase in `.env`, and a `localhost` certificate. It also runs `mkcert -install`, which adds mkcert's certificate authority to your system and may ask for your password once.

```
mkdir -p ~/semsec && cd ~/semsec
read -rsp "Passphrase for your Crypt4GH key: " P; echo "C4GH_RECRYPTOR_PRIVATE_KEY_PASSPHRASE=$P" > .env; chmod 600 .env; unset P
export C4GH_RECRYPTOR_COMPUTE_HOST=recryptor.semsec.bsc.es C4GH_RECRYPTOR_COMPUTE_PORT=8443
crypt4gh-recryptor-service user
```

Leave it running. In a second window, check it answers:

```
curl -sS https://localhost:61357/info
```

## 3. Let the browser trust the user service

The browser only talks to the user service if it trusts its certificate, which comes from mkcert's certificate authority.

### Windows

`mkcert -install` only added the authority inside WSL, so add it to Windows too. In WSL:

```
cp "$(mkcert -CAROOT)/rootCA.pem" /mnt/c/Users/Public/wsl-mkcert-rootCA.crt
```

Then in Windows PowerShell (no admin rights needed):

```
certutil -user -addstore Root C:\Users\Public\wsl-mkcert-rootCA.crt
```

Edge and Chrome use the Windows store. Firefox needs `security.enterprise_roots.enabled` set to `true` in `about:config`.

### macOS and Linux

Nothing to do: `mkcert -install` in step 2 added the authority to the system store, and to Firefox through the NSS tools. On Linux, Chrome uses the NSS store too.

Restart the browser and open https://localhost:61357/info. It should show the service's name without a certificate warning.

## 4. Make an encrypted test file

The same on all systems (on Windows, in WSL):

```
cd ~/semsec
printf "@r1\nACGTACGT\n+\nIIIIIIII\n" > reads.fastq
crypt4gh encrypt --recipient_pk c4gh_recryptor_user/user_keys/user_key.pub < reads.fastq > reads.fastqsanger.c4gh
```

On Windows, copy it where the browser can pick it up:

```
cp reads.fastqsanger.c4gh /mnt/c/Users/Public/
```

## 5. Set up storage in Galaxy

Log in to https://galaxy.semsec.bsc.es. Protected jobs need the history on your own S3 storage, so the encrypted outputs go straight from the compute host to your bucket.

1. User, Preferences, Manage Your Galaxy Storage: create a storage from "Any S3 Compatible Storage" with endpoint `https://semsec-galaxy:8443`, bucket `galaxy-c4gh`, and the demo access key and secret key (ask the admin).
2. Create a new history. Click the storage icon under its title and select the storage you just made.

## 6. Upload, authorize and run

1. Upload `reads.fastqsanger.c4gh` (on Windows from `C:\Users\Public\`, otherwise from `~/semsec/`). Galaxy detects the encryption and gives it the type `fastqsanger.c4gh`.
2. Expand the dataset and click the key icon. The browser asks your user service, and the dataset shows as authorized, with an expiry date.
3. Run "Concatenate datasets" (`cat1`) on it. The job runs on the separate Pulsar host and its output is encrypted for you.

## 7. Import a file from the EGA Live Outbox

Galaxy can import files straight from your EGA Live Outbox, the place where EGA makes the datasets you have access to available. You need an EGA account and access to a dataset, granted by its Data Access Committee, for example the Rare Disease Synthetic Dataset (EGAD00001008392).

EGA encrypts each file for the Crypt4GH public keys in your EGA profile. Your user service can only authorize files encrypted for its own key, so that key has to be in your profile.

1. Show your user service's public key (on Windows, in WSL):

   ```
   cat ~/semsec/c4gh_recryptor_user/user_keys/user_key.pub
   ```

   Log in at https://ega-archive.org, open your profile and add this key as a Crypt4GH public key. EGA takes a few hours to sync a new key.
2. In Galaxy, User, Preferences, Manage Your Remote File Sources: create one from "EGA Live Outbox" with your EGA username (not your email address) and your EGA password. If you registered an SSH key in your EGA profile, you can give that key instead of the password.
3. In a history on your storage from step 5, open the upload dialog and click "Choose remote files". Open "EGA Live Outbox", go to your dataset and pick a file. Galaxy detects the encryption and gives it an encrypted type, such as `vcf_bgzip.c4gh`. Large files take a while to import.
4. Authorize it with the key icon and run a tool on it, as in step 6.

## 8. Download and decrypt

Download the output from Galaxy (the disk icon). Then decrypt it, which asks for your passphrase and prints the same four lines as `reads.fastq`.

### Windows

Save the download to `C:\Users\Public\`, then in WSL:

```
cd ~/semsec
crypt4gh decrypt --sk c4gh_recryptor_user/user_keys/user_key.priv < "/mnt/c/Users/Public/<downloaded file>"
```

### macOS and Linux

```
cd ~/semsec
crypt4gh decrypt --sk c4gh_recryptor_user/user_keys/user_key.priv < ~/Downloads/<downloaded file>
```

## If the key icon fails

- "Could not reach the user service": the service from step 2 isn't running, or the browser doesn't trust its certificate (step 3).
- An error mentioning the compute service: the user service can't reach `recryptor.semsec.bsc.es:8443`. Check with `curl -sS -X POST https://recryptor.semsec.bsc.es:8443/get_compute_key_info` (on Windows, in WSL). A reachable service answers with a "Field required" error, since the check sends no key.
- The service still calls the old compute address after you changed it: the first start wrote the settings to `c4gh_recryptor_user/c4gh_config.yml`. Set `compute_host` and `compute_port` there as well.
