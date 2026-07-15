WORK IN PROGRESS -- NOT READY TO BE USED

# Square Terminal Plugin for Koha

[![CI](https://github.com/bywatersolutions/koha-plugin-square-terminal/actions/workflows/main.yml/badge.svg)](https://github.com/bywatersolutions/koha-plugin-square-terminal/actions/workflows/main.yml)
[![GitHub release (latest by date)](https://img.shields.io/github/v/release/bywatersolutions/koha-plugin-square-terminal)](https://github.com/bywatersolutions/koha-plugin-square-terminal/releases)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)

Adds Square Terminal card-present payments to Koha (patron payments + POS)

---

## ✨ Features

* Pay selected fines via Square from:

  * Patron **"Make a Payment"** page
  * Individual payment screen
  * Point of Sale (POS)
* Sends payment amount to Square Terminal
* Displays real-time payment status in Koha

**On success:**

* Patron payments: creates and applies credit to selected accountlines
* POS: submits Koha POS form to complete sale

---

## ⚙️ Requirements

* Koha **25.05+**
* Square account with:

  * Terminal device
  * Access token
* Square Terminal must be online and paired

---

## 🔧 Configuration

After installing the plugin, go to:

**Koha → Administration → Plugins → Square Terminal Plugin → Configure**

### Required settings

#### 1. SquareAccessToken

Your Square API access token (Sandbox or Production)

#### 2. Currency

Default: `USD`

#### 3. SquareVersion

Default: `2025-01-23`

#### 4. RegisterMapping (IMPORTANT)

Map Koha cash register IDs to Square device IDs.

Example:

```yaml
1: DEVICE_ID_HERE
2: ANOTHER_DEVICE_ID
```

* Left side = Koha `registerid`
* Right side = Square `device_id`

You can find your device ID in the Square Developer Dashboard.

---

## 💳 Usage

### Patron Payments

1. Go to a patron account
2. Select charges
3. Click **"Pay via Square"**
4. Follow prompts on the terminal
5. Payment is applied automatically in Koha

---

### Point of Sale (POS)

1. Add items to the POS sale
2. Click **"Pay via Square"**
3. Complete payment on the terminal
4. Koha will:

   * Set payment type to `CREDITCARD`
   * Submit the POS form
   * Complete the sale

---

## 🛠️ Troubleshooting

**"Missing checkout_id"**

* Check API response in browser console

**"No device mapped"**

* Verify `RegisterMapping` YAML

**Payment completes but Koha doesn't update**

* Check browser console for JS errors
* Confirm POS form submits

---

## 🛠️ Developer notes

### Releasing

Releases **must** go through `npm version`. Do not create tags or releases from the GitHub UI directly.

```bash
npm version patch    # or minor, or major
git push --follow-tags
```

This single command:

1. Updates `$VERSION` in `SquareTerminal.pm`
2. Updates `version` in `PLUGIN.yml`
3. Stamps the `[Unreleased]` section in `CHANGELOG.md` with the version and date
4. Creates a git tag (`v*.*.*`)
5. Opens the next development cycle in `CHANGELOG.md`

Pushing the tag triggers CI, which runs tests and (on success) builds the KPZ and creates the GitHub Release.

### Development setup

```bash
# Install Node.js dev dependencies (for version tooling)
npm install

# Build a KPZ locally
npx gulp build

# Run tests in KTD
ktd --name square-terminal --proxy --single-plugin ~/git/koha-plugins/square-terminal up -d
ktd --name square-terminal --wait-ready 120
ktd --name square-terminal --shell --run "cd /kohadevbox/koha && perl misc/devel/install_plugins.pl"
ktd --name square-terminal --shell --run "
  cd /kohadevbox/plugins/square-terminal &&
  export PERL5LIB=\$PERL5LIB:. &&
  prove -v -r t/
"
```

---

## 👩‍💻 Author

Laura Escamilla
ByWater Solutions
