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
Best way: npm (official) — latest + self-updating                                                                                                                                                                                                                                                                       ```bash
   npm install -g --ignore-scripts @earendil-works/pi-coding-agent                                                                                           ```
 Or the official installer, which pulls the same latest release:                                                                                                                                                                                                                                                         ```bash
   curl -fsSL https://pi.dev/install.sh | sh                                                                                                                 ```
 Both give you the current npm version (pi publishes updates to npm continuously), and pi updates itself — it checks pi.dev/api/latest-version at startup,   and you force it anytime with:
                                                                                                                                                             ```bash                                                                                                                                                       pi update --self        # update pi only
   pi update --all        
   
# update pi + packages
   
