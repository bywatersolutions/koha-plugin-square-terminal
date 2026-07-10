package Koha::Plugin::Com::ByWaterSolutions::SquareTerminal;

use Modern::Perl;

use base qw(Koha::Plugins::Base);

use C4::Auth;
use C4::Context;
use Koha::Notice::Messages;

use HTTP::Request::Common;
use LWP::UserAgent;
use Mojo::JSON qw(decode_json);

## Here we set our plugin version
our $VERSION         = "0.0.3";
our $MINIMUM_VERSION = "25.05";

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name            => 'Square Terminal Plugin',
    author          => 'Laura Escamilla',
    date_authored   => '2026-03-02',
    date_updated    => "2026-07-10",
    minimum_version => $MINIMUM_VERSION,
    maximum_version => undef,
    version         => $VERSION,
    description =>
      'Send card-present payments to Square Terminal hardware and post payments to Koha.',
};

sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    return $self;
}

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    unless ( $cgi->param('save') ) {
        my $template = $self->get_template( { file => 'configure.tt' } );

        $template->param(
            SquareAccessToken => $self->retrieve_data('SquareAccessToken'),
            SquareEnvironment => $self->retrieve_data('SquareEnvironment') || 'sandbox',
            Currency          => $self->retrieve_data('Currency') || 'USD',
            SquareVersion     => $self->retrieve_data('SquareVersion') || '2025-01-23',
            RegisterMapping   => $self->retrieve_data('RegisterMapping'),
            WebhookSignatureKey => $self->retrieve_data('WebhookSignatureKey'),
            WebhookUrl          => $self->retrieve_data('WebhookUrl'),
        );

        $self->output_html( $template->output() );
    }
    else {
        my $access_token =
            scalar $cgi->param('SquareAccessToken') // '';
        
        my $signature_key =
            scalar $cgi->param('WebhookSignatureKey') // '';

         # Keep existing secrets when the corresponding fields are left blank.
        $access_token ||= $self->retrieve_data('SquareAccessToken') // '';
        $signature_key ||= $self->retrieve_data('WebhookSignatureKey') // '';

        my $environment =
            scalar $cgi->param('SquareEnvironment') // 'sandbox';

        # Only permit known environment values.
        $environment = 'sandbox'
            unless $environment eq 'sandbox'
                || $environment eq 'production';

        my $data = {
                SquareAccessToken   => $access_token,
                SquareEnvironment   => $environment,
                Currency            => scalar $cgi->param('Currency') || 'USD',
                SquareVersion       => scalar $cgi->param('SquareVersion') || '2025-01-23',
                RegisterMapping     => scalar $cgi->param('RegisterMapping'),
                WebhookSignatureKey => $signature_key,
                WebhookUrl          => scalar $cgi->param('WebhookUrl'),
        };

        $self->store_data($data);
        $self->go_home();
    }
}

sub intranet_js {
    return <<'JS';
<script>
$(document).ready(function() {

    function ensureSquareModal() {
        if ($('#squareModal').length) return;

            $('body').append(`
          <style>
            .square-processing-wrap {
              display: flex;
              flex-direction: column;
              align-items: center;
              justify-content: center;
              gap: 0.75rem;
              min-height: 120px;
              text-align: center;
            }

            .square-processing-spinner {
              width: 2rem;
              height: 2rem;
              border: 0.25rem solid #d1d5db;
              border-top-color: #0d6efd;
              border-radius: 50%;
              animation: square-spin 0.8s linear infinite;
            }

            @keyframes square-spin {
              to { transform: rotate(360deg); }
            }
          </style>

          <div class="modal fade" id="squareModal" role="dialog" aria-hidden="true">
            <div class="modal-dialog">
              <div class="modal-content">
                <div class="modal-header">
                  <h4 class="modal-title">Square Terminal processing</h4>
                </div>
                <div id="squareModalBody" class="modal-body">
                  <div class="square-processing-wrap">
                    <div class="square-processing-spinner" aria-hidden="true"></div>
                    <div id="squareStatusText" aria-live="polite">
                      Processing payment... Please follow prompts on the Square Terminal.
                    </div>
                  </div>
                </div>
                <div class="modal-footer">
                  <button id="square-cancel" type="button" class="btn btn-default">Cancel</button>
                </div>
              </div>
            </div>
          </div>
        `);
        }

    function renderSquareButton(id, label) {
        return `<input style="margin-left: 5px" type="button"
                       id="${id}"
                       name="${id}"
                       value="${label}"
                       class="submit btn btn-primary">`;
    }

    function parseAmountToCents(amount) {
    if (amount == null) return null;

    const normalized = String(amount)
        .trim()
        .replace(/[$,]/g, '');

    if (!/^\d+(\.\d{1,2})?$/.test(normalized)) {
        console.log('Invalid Square amount:', {
            original: amount,
            normalized: normalized,
            characters: Array.from(String(amount)).map(char => char.charCodeAt(0))
        });

        return null;
    }

    const cents = Math.round(Number(normalized) * 100);

    return Number.isSafeInteger(cents) && cents > 0
        ? cents
        : null;
}

    function launchSquarePayment(accountlineIds, defaultAmount) {
        if (!accountlineIds || !accountlineIds.length) {
            alert("No charges selected.");
            return;
        }

        const accountlines = encodeURIComponent(accountlineIds.join(","));
        const debitUrl = `/api/v1/contrib/square_terminal/get_debits/${accountlines}`;

        $.getJSON(debitUrl, function(data) {
            const suggestedAmount = defaultAmount || data.total;
            let amount = prompt("Enter amount to collect", suggestedAmount);
            if (amount == null) return;

            const amountCents = parseAmountToCents(amount);
            if (amountCents == null) {
                alert(`The amount "${amount}" is invalid. Please specify as a currency format (e.g. 1.00)`);
                return;
            }

            const createUrl = `/api/v1/contrib/square_terminal/checkout/${accountlines}?amount=${encodeURIComponent(amountCents)}`;

            $.ajax({
                url: createUrl,
                method: 'POST',
                dataType: 'json',
                success: function(resp) {
                    const checkoutId = resp.checkout_id;
                    if (!checkoutId) {
                        alert("ERROR: Missing checkout_id from server");
                        return;
                    }

                    $('#squareStatusText').text('Processing payment... Please follow prompts on the Square Terminal.');
                    const squareModalEl = document.getElementById('squareModal');
                    const squareModal = bootstrap.Modal.getOrCreateInstance(squareModalEl, {
                            backdrop: 'static',
                            keyboard: false
                    });
                    squareModal.show();

                    const statusUrl = `/api/v1/contrib/square_terminal/checkout/status/${encodeURIComponent(checkoutId)}`;

                    let pollCount = 0;

                                        let pollTimer = setInterval(function() {
                        pollCount++;

                        $.getJSON(statusUrl, function(statusResp) {
                            const checkout = statusResp.checkout || {};
                            const status = checkout.status || statusResp.status || '';

                            console.log("Square checkout status:", statusResp?.checkout?.status);
                            console.log("Full Square checkout response:", JSON.stringify(statusResp, null, 2));

                            let friendlyStatus = status || 'UNKNOWN';
                            if (status === 'PENDING') {
                                friendlyStatus = 'Square payment is processing... Waiting for customer on terminal.';
                            } else if (status === 'IN_PROGRESS') {
                                friendlyStatus = 'Square payment is processing... Customer is interacting with terminal.';
                            } else if (status === 'COMPLETED') {
                                friendlyStatus = 'Payment complete!';
                            }

                            $('#squareStatusText').text(friendlyStatus);

                            if (status === 'CANCELED' || status === 'CANCELLED' || status === 'FAILED') {
                                clearInterval(pollTimer);
                                bootstrap.Modal.getOrCreateInstance(document.getElementById('squareModal')).hide();

                                const dismissUrl = `/api/v1/contrib/square_terminal/checkout/dismiss/${encodeURIComponent(checkoutId)}`;
                                $.ajax({ url: dismissUrl, method: 'POST' });

                                alert("Transaction canceled or failed.");
                                return;
                            }

                            if (status === 'COMPLETED') {
                                clearInterval(pollTimer);

                                const finalizeUrl = `/api/v1/contrib/square_terminal/checkout/finalize/${encodeURIComponent(checkoutId)}/${accountlines}`;

                                $.ajax({
                                    url: finalizeUrl,
                                    method: 'POST',
                                    dataType: 'json',
                                    success: function(finalizeResp) {
                                        bootstrap.Modal.getOrCreateInstance(document.getElementById('squareModal')).hide();

                                        const dismissUrl = `/api/v1/contrib/square_terminal/checkout/dismiss/${encodeURIComponent(checkoutId)}`;
                                        $.ajax({ url: dismissUrl, method: 'POST' });

                                        const paymentId = finalizeResp.payment_id;

                                        $('#pay-via-square-individual, #pay-selected-via-square')
                                            .prop('disabled', true);

                                        const currentUrl = new URL(window.location.href);
                                        const borrowernumber = currentUrl.searchParams.get('borrowernumber');

                                        const accountUrl = borrowernumber
                                            ? `/cgi-bin/koha/members/boraccount.pl?borrowernumber=${encodeURIComponent(borrowernumber)}`
                                            : window.location.href;

                                        const openReceipt = paymentId && window.confirm(
                                                "Payment completed successfully.\n\nWould you like to open the receipt?"
                                            );

                                        if (openReceipt) {
                                            const receiptUrl =
                                                `/cgi-bin/koha/members/printfeercpt.pl?action=print&accountlines_id=${encodeURIComponent(paymentId)}`;

                                            window.open(receiptUrl, '_blank');
                                        }
                                        window.location.href = accountUrl;
                                    },
                                    error: function(xhr) {
                                        bootstrap.Modal.getOrCreateInstance(document.getElementById('squareModal')).hide();
                                        alert("ERROR finalizing payment in Koha: " + (xhr.responseText || xhr.statusText));
                                    }
                                });

                                return;
                            }

                            if (pollCount >= 60) {
                                clearInterval(pollTimer);
                                bootstrap.Modal.getOrCreateInstance(document.getElementById('squareModal')).hide();

                                alert(`Square checkout timed out. Last status: ${status || 'UNKNOWN'}`);

                                const dismissUrl = `/api/v1/contrib/square_terminal/checkout/dismiss/${encodeURIComponent(checkoutId)}`;
                                $.ajax({ url: dismissUrl, method: 'POST' });

                                return;
                            }
                        });
                    }, 1000);

                    $('#square-cancel').off('click').on('click', function() {
                        clearInterval(pollTimer);

                        const dismissUrl = `/api/v1/contrib/square_terminal/checkout/dismiss/${encodeURIComponent(checkoutId)}`;
                        $.ajax({
                            url: dismissUrl,
                            method: 'POST',
                            complete: function() {
                                bootstrap.Modal.getOrCreateInstance(document.getElementById('squareModal')).hide();
                            }
                        });
                    });
                },

                error: function(xhr) {
    console.log("checkout error xhr", xhr);
    let msg = "ERROR creating Square checkout";
    try {
        const j = xhr.responseJSON || JSON.parse(xhr.responseText);
        if (j && (j.description || j.error)) {
            msg = `${j.error || 'ERROR'}: ${j.description || ''}`;
        } else if (xhr.responseText) {
            msg = xhr.responseText;
        }
    } catch(e) {
        if (xhr.responseText) {
            msg = xhr.responseText;
        }
    }
    alert(msg);
                }
        });
    });
    }

function launchSquarePosPayment(defaultAmount, registerId) {
    if (!defaultAmount || defaultAmount === '0.00') {
        alert("No POS total found.");
        return;
    }

    if (!registerId) {
        alert("Please select a cash register.");
        return;
    }

    const amountCents = parseAmountToCents(defaultAmount);

    if (amountCents == null) {
        alert(
            `The amount "${defaultAmount}" is invalid. ` +
            'Please specify it as a currency format, such as 1.00.'
        );
        return;
    }

    const createUrl =
        `/api/v1/contrib/square_terminal/checkout/pos` +
        `?amount=${encodeURIComponent(amountCents)}` +
        `&register_id=${encodeURIComponent(registerId)}`;

        $.ajax({
            url: createUrl,
            method: 'POST',
            dataType: 'json',
            success: function(resp) {
                const checkoutId = resp.checkout_id;
                if (!checkoutId) {
                    alert("ERROR: Missing checkout_id from server");
                    return;
                }

                $('#squareStatusText').text('Square payment is processing... Please follow prompts on the Square Terminal.');
                const squareModalEl = document.getElementById('squareModal');
                const squareModal = bootstrap.Modal.getOrCreateInstance(squareModalEl, {
                    backdrop: 'static',
                    keyboard: false
                });
                squareModal.show();

                const statusUrl = `/api/v1/contrib/square_terminal/checkout/status/${encodeURIComponent(checkoutId)}`;
                let pollCount = 0;

                let pollTimer = setInterval(function() {
                    pollCount++;

                    $.getJSON(statusUrl, function(statusResp) {
                        const checkout = statusResp.checkout || {};
                        const status = checkout.status || statusResp.status || '';

                        let friendlyStatus = status || 'UNKNOWN';
                        if (status === 'PENDING') {
                            friendlyStatus = 'Square payment is processing... Waiting for customer on terminal.';
                        } else if (status === 'IN_PROGRESS') {
                            friendlyStatus = 'Square payment is processing... Customer is interacting with terminal.';
                        } else if (status === 'COMPLETED') {
                            friendlyStatus = 'Payment complete!';
                        }

                        $('#squareStatusText').text(friendlyStatus);

                        if (status === 'CANCELED' || status === 'CANCELLED' || status === 'FAILED') {
                            clearInterval(pollTimer);
                            bootstrap.Modal.getOrCreateInstance(document.getElementById('squareModal')).hide();

                            const dismissUrl = `/api/v1/contrib/square_terminal/checkout/dismiss/${encodeURIComponent(checkoutId)}`;
                            $.ajax({ url: dismissUrl, method: 'POST' });

                            alert("Transaction canceled or failed.");
                            return;
                        }

                        if (status === 'COMPLETED') {
                            clearInterval(pollTimer);

                            const dismissUrl = `/api/v1/contrib/square_terminal/checkout/dismiss/${encodeURIComponent(checkoutId)}`;
                            $.ajax({ url: dismissUrl, method: 'POST' });

                            bootstrap.Modal.getOrCreateInstance(document.getElementById('squareModal')).hide();

                            // Make Koha treat the POS payment as a credit card payment
                            $('#payment_type').val('CREDITCARD');

                            // Submit the normal POS form so Koha builds hidden sales[] inputs
                            // and runs the normal purchase flow.
                            $('#payForm').trigger('submit');
                            return;
                        }

                        if (pollCount >= 60) {
                            clearInterval(pollTimer);
                            bootstrap.Modal.getOrCreateInstance(document.getElementById('squareModal')).hide();

                            alert(`Square checkout timed out. Last status: ${status || 'UNKNOWN'}`);

                            const dismissUrl = `/api/v1/contrib/square_terminal/checkout/dismiss/${encodeURIComponent(checkoutId)}`;
                            $.ajax({ url: dismissUrl, method: 'POST' });

                            return;
                        }
                    });
                }, 1000);

                $('#square-cancel').off('click').on('click', function() {
                    clearInterval(pollTimer);

                    const dismissUrl = `/api/v1/contrib/square_terminal/checkout/dismiss/${encodeURIComponent(checkoutId)}`;
                    $.ajax({
                        url: dismissUrl,
                        method: 'POST',
                        complete: function() {
                            bootstrap.Modal.getOrCreateInstance(document.getElementById('squareModal')).hide();
                        }
                    });
                });
            },
            error: function(xhr) {
                console.log("checkout error xhr", xhr);
                let msg = "ERROR creating Square checkout";
                try {
                    const j = xhr.responseJSON || JSON.parse(xhr.responseText);
                    if (j && (j.description || j.error)) {
                        msg = `${j.error || 'ERROR'}: ${j.description || ''}`;
                    } else if (xhr.responseText) {
                        msg = xhr.responseText;
                    }
                } catch(e) {
                    if (xhr.responseText) {
                        msg = xhr.responseText;
                    }
                }
                alert(msg);
            }
        });
    }

    function initMakePaymentPage() {
        if (!$('#writeoff-selected').length || $('#pay-selected-via-square').length) return;

        const buttonHtml = renderSquareButton('pay-selected-via-square', 'Pay via Square');
        $(buttonHtml).insertAfter('#writeoff-selected');

        function selectedAccountlineIds() {
            let ids = [];
            $(".cb:checked").each(function() {
                const id = $(this).attr("name").split("_")[2];
                if (id) ids.push(id);
            });
            return ids;
        }

        function setButtonState() {
            if ($('.cb:checkbox:checked').length > 0) {
                $('#pay-selected-via-square').removeAttr("disabled");
            } else {
                $('#pay-selected-via-square').attr("disabled", "disabled");
            }
        }

        $('#pay-selected-via-square').attr("disabled", "disabled");
        setButtonState();
        $('.cb').on("change", setButtonState);

        $('#pay-selected-via-square').on('click', function(e) {
            e.preventDefault();
            launchSquarePayment(selectedAccountlineIds(), null);
        });
    }

    function initIndividualPaymentPage() {
        if (!$('#payindivfine').length || $('#pay-via-square-individual').length) return;

        const buttonHtml = renderSquareButton('pay-via-square-individual', 'Pay via Square');
        $(buttonHtml).insertAfter('#payindivfine .action input[type="submit"].btn.btn-primary');

        $('#pay-via-square-individual').on('click', function(e) {
            e.preventDefault();

            const accountlineId = $('#accountlines_id').val();
            const paid = $('#paid').val();

            if (!accountlineId) {
                alert("No accountline_id found on individual payment page.");
                return;
            }

            launchSquarePayment([accountlineId], paid);
        });
    }


        function initPosPage() {
        if (!$('#submitbutton').length || !$('#sale').length || $('#pay-via-square-pos').length) return;

        const buttonHtml = renderSquareButton('pay-via-square-pos', 'Pay via Square');
        $(buttonHtml).insertAfter('#submitbutton');

        $('#pay-via-square-pos').on('click', function(e) {
            e.preventDefault();

            const paid = $('#paid').val();
            const registerId = $('#registerid').val();

            if (!paid || paid === '0.00') {
                alert("No POS total found.");
                return;
            }

            if (!registerId) {
                alert("Please select a cash register.");
                return;
            }

            launchSquarePosPayment(paid, registerId);
        });
    }

    ensureSquareModal();
    initMakePaymentPage();
    initIndividualPaymentPage();
    initPosPage();
});
</script>
JS
}

sub install {
    my ( $self, $args ) = @_;

    return 1;
}

sub upgrade {
    my ( $self, $args ) = @_;

    return 1;
}

sub uninstall() {
    my ( $self, $args ) = @_;

    return 1;
}

sub api_routes {
    my ( $self, $args ) = @_;

    my $spec_str = $self->mbf_read('openapi.json');
    my $spec     = decode_json($spec_str);

    return $spec;
}

sub api_namespace {
    my ($self) = @_;

    return 'square_terminal';
}

1;
