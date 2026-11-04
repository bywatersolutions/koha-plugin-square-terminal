# Square Terminal Plugin for Koha

[![CI](https://github.com/bywatersolutions/koha-plugin-square-terminal/actions/workflows/main.yml/badge.svg)](https://github.com/bywatersolutions/koha-plugin-square-terminal/actions/workflows/main.yml)
[![GitHub release (latest by date)](https://img.shields.io/github/v/release/bywatersolutions/koha-plugin-square-terminal)](https://github.com/bywatersolutions/koha-plugin-square-terminal/releases)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)

Adds Square Terminal card-present payment support to Koha, allowing libraries to accept payments through Square Terminal devices directly from patron accounts and the Koha Point of Sale (POS).

---

## ✨ Features

### Patron payments
- Pay individual charges or multiple selected accountlines.
- Initiate payments directly from a patron's account.
- Send payment requests to an assigned Square Terminal.
- Display real-time checkout status in Koha.
- Automatically apply successful payments to the selected accountlines.

### Point of Sale (POS)
- Accept Square Terminal payments through Koha POS.
- Use the existing Koha POS payment workflow.
- Automatically set the payment type to `CREDITCARD`.
- Validate completed checkout amounts before submitting the POS transaction.
- Prevent duplicate payment submissions.

### Configuration and device management
- Configure Square Sandbox or Production environments.
- Discover available Square Terminal devices directly from Square.
- Automatically retrieve available Koha cash registers.
- Assign Square Terminal devices to Koha cash registers using dropdown selections.
- Add multiple register/device assignments.
- Validate register and device mappings before saving.
- Store configuration through the Koha plugin interface.

### Payment safeguards
- Verify Square checkout completion before finalizing payments.
- Validate payment amounts and currencies.
- Refresh outstanding accountline balances before applying payments.
- Protect against duplicate payment finalization.
- Handle canceled, failed, and timed-out checkouts.

---

## ⚙️ Requirements

- Koha **25.11 or later**.
- A Square account with API access.
- Square Terminal device(s).
- Square access token.
- An existing Koha cash register configured for the appropriate library.

Square Terminal devices must be online and available to accept checkout requests.

---

## Configuration

Navigate to:

**Koha → Administration → Plugins → Square Terminal Plugin → Configure**

### 1. Square access token

Enter your Square API access token.

Use a Sandbox access token for testing or a Production access token for live transactions.

Treat this token like a password.

### 2. Square environment

Choose the environment:

- **Sandbox:** Uses Square test devices and simulated payments.
- **Production:** Uses live Square services and processes real payments.

Make sure your access token matches the selected environment.

### 3. Currency

Specify the ISO currency code used for payments.

Default: `USD`

### 4. Square API version

Specify the Square API version.

Default: `2025-01-23`

Leave the default unless a different version is required.

### 5. Webhook configuration

Configure the webhook settings when using Square webhook notifications:

- **Webhook URL:** The publicly accessible HTTPS endpoint configured in your Square Developer Dashboard.
- **Webhook signature key:** The signature key generated for the corresponding Square webhook subscription.

The URL must match the configured Square webhook notification URL exactly, including its path.

### 6. Discover Square devices

Click **Discover Square devices** to retrieve the available terminals associated with your Square account.

Discovered devices are displayed with their names, models, and device IDs.

### 7. Square Terminal assignments

Assign a Square Terminal to each Koha cash register.

For each assignment:

1. Select an existing Koha cash register.
2. Select a discovered Square Terminal.
3. Use **Add another register / device** to configure additional assignments.
4. Save your configuration.

A Koha cash register must have a valid Square Terminal assignment before it can process payments.

Register mappings are managed through the configuration interface rather than manually editing YAML.

---

## 💳 Usage

### Patron payments

1. Open a patron account in the staff interface.
2. Select one or more outstanding charges.
3. Click **Pay via Square**.
4. Follow the prompts displayed on the assigned Square Terminal.
5. Once the payment is completed, Koha automatically applies the payment to the selected charges.

The plugin verifies the completed Square transaction and refreshes outstanding balances before recording the Koha payment.

### Point of Sale (POS)

1. Navigate to the Koha Point of Sale.
2. Add the desired items to the sale.
3. Select the appropriate Koha cash register.
4. Click **Pay via Square**.
5. Confirm the amount to collect.
6. Follow the prompts on the assigned Square Terminal.
7. Once Square confirms successful payment, Koha submits the normal POS payment workflow.

The plugin:
- Sets the payment type to `CREDITCARD`.
- Preserves Koha's normal POS submission process.
- Validates the completed Square checkout amount.
- Prevents duplicate form submissions.

---

## 🧪 Sandbox Testing

Before using the plugin in Production, test it with Square Sandbox credentials and a supported Sandbox Terminal or simulator.

Recommended test scenarios:

- Successful single-charge patron payment.
- Successful multiple-charge patron payment.
- Successful POS payment.
- Canceled checkout.
- Failed checkout.
- Checkout timeout.
- Invalid or missing register/device assignment.
- Payment amount mismatch.
- Outstanding balance changes during checkout.
- Repeated checkout finalization requests.

Verify that successful Square transactions are recorded correctly in Koha and that unsuccessful transactions do not create unintended Koha payments.

---

## 🛠️ Troubleshooting

**Missing checkout ID**
- Check the browser console and Koha logs.
- Verify Square API credentials and environment settings.

**No Square device mapped for this register**
- Open the plugin configuration.
- Discover Square devices.
- Confirm that the selected Koha cash register has an assigned Square Terminal.

**Square device discovery returns no devices**
- Verify your access token.
- Confirm the selected Square environment.
- Check that devices are available to the Square account.

**Payment completes but Koha does not update**
- Check the browser console for JavaScript errors.
- Verify the checkout status response.
- Check Koha logs for payment finalization errors.
- Confirm the payment amount and currency match the original checkout.

**Webhook signature validation fails**
- Verify the webhook URL matches the Square Developer Dashboard configuration exactly.
- Verify the webhook signature key.

---

## 🛠️ Developer Notes

### Releasing

Releases must go through `npm version`. Do not create tags or releases directly through the GitHub UI.

```bash
npm version patch    # or minor, or major
git push --follow-tags
```

This process:

1. Updates `$VERSION` in `SquareTerminal.pm`.
2. Updates the version in `PLUGIN.yml`.
3. Stamps the `[Unreleased]` section in `CHANGELOG.md` with the version and date.
4. Creates a Git tag (`v*.*.*`).
5. Opens the next development cycle in `CHANGELOG.md`.

Pushing the tag triggers CI, which runs tests and, on success, builds the KPZ and creates the GitHub Release.

### Development setup

Install Node.js development dependencies:

```bash
npm install
```

Build a KPZ locally:

```bash
npx gulp build
```

Run tests in KTD:

```bash
ktd --name square-terminal --proxy --single-plugin ~/git/koha-plugins/square-terminal up -d

ktd --name square-terminal --wait-ready 120

ktd --name square-terminal --shell --run "cd /kohadevbox/koha && perl misc/devel/install_plugins.pl"

ktd --name square-terminal --shell --run "\
  cd /kohadevbox/plugins/square-terminal &&\
  export PERL5LIB=\$PERL5LIB:. &&\
  prove -v -r t/\
"
```

---

## 👩‍💻 Author

Laura Escamilla  
ByWater Solutions

---

**License:** GNU General Public License v3.0
