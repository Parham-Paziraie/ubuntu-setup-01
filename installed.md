# Installed Manually

Tools set up outside `ubuntu-26.04-setup.sh`.

## Pi coding agent

The installer pulls the npm package `@earendil-works/pi-coding-agent`, so it
needs Node and npm already on PATH - run it after section 5 of the setup script
(nvm + Node LTS).

```bash
curl -fsSL https://pi.dev/install.sh | sh
```

Once the installation completes, reload your shell configuration or restart the
terminal:

```bash
source ~/.bashrc
```
