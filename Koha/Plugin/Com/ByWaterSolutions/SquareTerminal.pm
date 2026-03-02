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
our $VERSION         = "{VERSION}";
our $MINIMUM_VERSION = "25.05";

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name            => 'Square Terminal Plugin',
    author          => 'Laura Escamilla',
    date_authored   => '2026-03-02',
    date_updated    => "2026-03-02",
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
            Currency          => $self->retrieve_data('Currency') || 'USD',
            SquareVersion     => $self->retrieve_data('SquareVersion') || '2025-01-23',
            RegisterMapping   => $self->retrieve_data('RegisterMapping'),
            WebhookSignatureKey => $self->retrieve_data('WebhookSignatureKey'),
            WebhookUrl          => $self->retrieve_data('WebhookUrl'),
        );

        $self->output_html( $template->output() );
    }
    else {
        $self->store_data(
            {
                SquareAccessToken   => scalar $cgi->param('SquareAccessToken'),
                Currency            => scalar $cgi->param('Currency') || 'USD',
                SquareVersion       => scalar $cgi->param('SquareVersion') || '2025-01-23',
                RegisterMapping     => scalar $cgi->param('RegisterMapping'),
                WebhookSignatureKey => scalar $cgi->param('WebhookSignatureKey'),
                WebhookUrl          => scalar $cgi->param('WebhookUrl'),
            }
        );
        $self->go_home();
    }
}

sub intranet_js {
    return <<'JS';
<script>
$(document).ready(function() {

    // Insert button + modal
    const squareButtonHtml = `
      <input style="margin-left: 5px" type="submit"
             id="pay-selected-via-square"
             name="pay_via_square"
             value="Pay via Square"
             class="submit"
             disabled="disabled">

      <div class="modal fade" id="squareModal" role="dialog" aria-hidden="true">
        <div class="modal-dialog">
          <div class="modal-content">
            <div class="modal-header">
              <h4 class="modal-title">Square Terminal processing</h4>
            </div>
            <div id="squareModalBody" class="modal-body">
              Payment in progress...
            </div>
            <div class="modal-footer">
              <button id="square-cancel" type="button" class="btn btn-default">Cancel</button>
            </div>
          </div>
        </div>
      </div>
    `;

    $(squareButtonHtml).insertAfter('#writeoff-selected');

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

    // Initial state + on checkbox change
    setButtonState();
    $('.cb').on("change", setButtonState);

    $("#pay-selected-via-square").on("click", function(e) {
        e.preventDefault();

        const ids = selectedAccountlineIds();
        if (!ids.length) return;

        const accountlines = encodeURIComponent(ids.join(","));

        const debitUrl = `/api/v1/contrib/square_terminal/get_debits/${accountlines}`;
        $.getJSON(debitUrl, function(data) {
            const total = data.total;
            let amount = prompt("Enter amount to collect", total);
            if (amount == null) return;

            const regex = /^\d*(\.\d{1,2})?\s*$/;
            if (!regex.test(amount)) {
                alert(`The amount "${amount}" is invalid. Please specify as a currency format ( e.g. 1.00 )`);
                return;
            }

            const amountCents = Math.round(parseFloat(amount) * 100);

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

                    $('#squareModalBody').text('Payment in progress... Follow prompts on the Square Terminal.');
                    $('#squareModal').modal({ backdrop: 'static', keyboard: false });

                    const statusUrl = `/api/v1/contrib/square_terminal/checkout/status/${encodeURIComponent(checkoutId)}`;

                    let pollTimer = setInterval(function() {
                        $.getJSON(statusUrl, function(statusResp) {
                            const checkout = statusResp.checkout || {};
                            const status = checkout.status || statusResp.status || '';

                            // Helpful status messages
                            if (status) {
                                $('#squareModalBody').text(`Status: ${status}`);
                            }

                            if (status === 'CANCELED' || status === 'CANCELLED' || status === 'FAILED') {
                                clearInterval(pollTimer);
                                $('#squareModal').modal('hide');

                                // best-effort dismiss
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
                                        $('#squareModal').modal('hide');

                                        // best-effort dismiss after completion
                                        const dismissUrl = `/api/v1/contrib/square_terminal/checkout/dismiss/${encodeURIComponent(checkoutId)}`;
                                        $.ajax({ url: dismissUrl, method: 'POST' });

                                        const paymentId = finalizeResp.payment_id;
                                        if (!paymentId) {
                                            location.reload();
                                            return;
                                        }

                                        const receiptUrl = `/cgi-bin/koha/members/printfeercpt.pl?action=print&accountlines_id=${encodeURIComponent(paymentId)}`;
                                        const child = window.open(receiptUrl, "Receipt", 'width=600,height=600,resizable=yes,toolbar=false,scrollbars=yes');

                                        const timer = setInterval(function() {
                                            if (!child || child.closed) {
                                                clearInterval(timer);
                                                location.reload();
                                            }
                                        }, 500);
                                    },
                                    error: function(xhr) {
                                        $('#squareModal').modal('hide');
                                        alert("ERROR finalizing payment in Koha: " + (xhr.responseText || xhr.statusText));
                                    }
                                });
                            }
                        });
                    }, 1000);

                    // Cancel button (unbind first to avoid stacking handlers)
                    $('#square-cancel').off('click').on('click', function() {
                        clearInterval(pollTimer);

                        const dismissUrl = `/api/v1/contrib/square_terminal/checkout/dismiss/${encodeURIComponent(checkoutId)}`;
                        $.ajax({
                            url: dismissUrl,
                            method: 'POST',
                            complete: function() {
                                $('#squareModal').modal('hide');
                            }
                        });
                    });
                },
                error: function(xhr) {
                    let msg = "ERROR creating Square checkout";
                    try {
                        const j = JSON.parse(xhr.responseText);
                        if (j && (j.description || j.error)) msg = `${j.error || 'ERROR'}: ${j.description || ''}`;
                    } catch(e) {}
                    alert(msg);
                }
            });

        });
    });

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
