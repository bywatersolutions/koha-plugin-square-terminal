package Koha::Plugin::Com::ByWaterSolutions::SquareTerminal::API;

use Modern::Perl;
use Mojo::Base 'Mojolicious::Controller';

use Digest::SHA qw( hmac_sha256 );
use MIME::Base64 qw( encode_base64 );
use HTTP::Headers;
use HTTP::Request::Common qw( GET POST );
use LWP::UserAgent;
use Mojo::JSON qw( encode_json decode_json true );
use Try::Tiny;
use YAML qw( Load );

use C4::Context;
use Koha::Account;
use Koha::Account::Lines;
use Koha::Number::Price;

=head1 API

Square Terminal integration endpoints

=cut

# ---------------------------
# Public endpoints
# ---------------------------

sub get_debits {
    warn "Koha::Plugin::Com::ByWaterSolutions::SquareTerminal::API::get_debits";
    my $c = shift->openapi->valid_input or return;

    my $accountline_ids = $c->param('accountlines') // '';
    my @ids = grep { $_ =~ /^\d+$/ } split( /,/, $accountline_ids );

    return $c->render(
        status => 400,
        format => 'json',
        json   => { error => 'BAD_REQUEST', description => 'No valid accountline ids provided' }
    ) unless @ids;

    my $accountlines = Koha::Account::Lines->search( { accountlines_id => \@ids } )->unblessed;

    my $total = 0;
    $total += $_->{amountoutstanding} for @$accountlines;
    my $total_edit = Koha::Number::Price->new($total)->format_for_editing;

    return $c->render(
        status => 200,
        format => 'json',
        json   => { total => $total_edit, accountlines => $accountlines }
    );
}

=head2 create_checkout

Starts a Square Terminal checkout for the current Koha register/device mapping.

Path params (to match your current style):
- accountlines: comma separated accountlines_id values
- amount: integer cents (optional; if omitted we'll compute from accountlines)

Returns:
- checkout_id
- status (initial)
=cut

sub create_checkout {
    warn "Koha::Plugin::Com::ByWaterSolutions::SquareTerminal::API::create_checkout";
    my $c = shift->openapi->valid_input or return;

    my $accountline_ids = $c->param('accountlines') // '';
    my @ids = grep { $_ =~ /^\d+$/ } split( /,/, $accountline_ids );

    return $c->render(
        status => 400, format => 'json',
        json   => { error => 'BAD_REQUEST', description => 'No valid accountline ids provided' }
    ) unless @ids;

    my @accountlines = Koha::Account::Lines->search( { accountlines_id => \@ids } )->as_list;

    # Compute amount from outstanding unless a cents amount is supplied
    my $amount_cents = $c->param('amount');
    if ( defined $amount_cents && $amount_cents ne '' ) {
        return $c->render(
            status => 400, format => 'json',
            json   => { error => 'BAD_REQUEST', description => 'Amount must be integer cents' }
        ) unless $amount_cents =~ /^\d+$/;
    } else {
        my $total = 0;
        $total += $_->amountoutstanding for @accountlines;
        $amount_cents = int( sprintf( "%.0f", $total * 100 ) );
    }

    my $outstanding_total = 0;
        $outstanding_total += $_->amountoutstanding for @accountlines;

    my $outstanding_cents =
        int( sprintf( '%.0f', $outstanding_total * 100 ) );

    return $c->render(
        status => 400,
        format => 'json',
        json   => {
            error       => 'AMOUNT_EXCEEDS_BALANCE',
            description => 'Payment amount exceeds the selected outstanding balance',
      }   
    ) if $amount_cents > $outstanding_cents;

    return $c->render(
        status => 400, format => 'json',
        json   => { error => 'BAD_REQUEST', description => 'Amount must be > 0' }
    ) unless $amount_cents > 0;

    my $self   = Koha::Plugin::Com::ByWaterSolutions::SquareTerminal->new({});
    my $token  = $self->retrieve_data('SquareAccessToken') // '';
    my $cur    = $self->retrieve_data('Currency') // 'USD';
    my $square_version = $self->retrieve_data('SquareVersion') // '2025-01-23';
    my $environment = $self->retrieve_data('SquareEnvironment') // 'sandbox';

    return $c->render(
        status => 500, format => 'json',
        json   => { error => 'CONFIG', description => 'SquareAccessToken not configured' }
    ) unless $token;

    my $device_id = _device_id_for_register($self);
    return $c->render(
        status => 404, format => 'json',
        json   => { error => 'TERM', description => 'No Square device_id mapped for this register' }
    ) unless $device_id;

    my $idempotency_key = _uuid();

    my $payload = {
        idempotency_key => $idempotency_key,
        checkout => {
            amount_money => {
                amount   => 0 + $amount_cents,
                currency => $cur,
            },
            device_options => {
                device_id => $device_id,
            },
            note => "Koha fees payment",
            reference_id => join( ',', @ids ),
        }
    };

    my $res = _square_request(
        token         => $token,
        square_version=> $square_version,
        method        => 'POST',
        environment   => $environment,
        path          => '/v2/terminals/checkouts',
        payload       => $payload,
    );

    return $c->render(
        status => $res->{status},
        format => 'json',
        json   => $res->{json} // { error => 'SQUARE', description => $res->{error} // 'Unknown error' }
    ) unless $res->{ok};

    my $checkout = $res->{json}->{checkout};
    return $c->render(
        status => 200,
        format => 'json',
        json   => {
            checkout_id      => $checkout->{id},
            status           => $checkout->{status},
            idempotency_key  => $idempotency_key,
            amount_cents     => 0 + $amount_cents,
            accountlines     => join(',', @ids),
        }
    );
}

sub create_pos_checkout {
    warn "Koha::Plugin::Com::ByWaterSolutions::SquareTerminal::API::create_pos_checkout";
    my $c = shift->openapi->valid_input or return;

    my $amount_cents = $c->param('amount');
    my $register_id  = $c->param('register_id');

    return $c->render(
        status => 400,
        format => 'json',
        json   => { error => 'BAD_REQUEST', description => 'amount must be integer cents' }
    ) unless defined $amount_cents && $amount_cents =~ /^\d+$/ && $amount_cents > 0;

    return $c->render(
        status => 400,
        format => 'json',
        json   => { error => 'BAD_REQUEST', description => 'register_id required' }
    ) unless defined $register_id && $register_id =~ /^\d+$/;

    my $self   = Koha::Plugin::Com::ByWaterSolutions::SquareTerminal->new({});
    my $token  = $self->retrieve_data('SquareAccessToken') // '';
    my $cur    = $self->retrieve_data('Currency') // 'USD';
    my $square_version = $self->retrieve_data('SquareVersion') // '2025-01-23';
    my $environment = $self->retrieve_data('SquareEnvironment') // 'sandbox';

    return $c->render(
        status => 500,
        format => 'json',
        json   => { error => 'CONFIG', description => 'SquareAccessToken not configured' }
    ) unless $token;

    my $device_id = _device_id_for_register( $self, $register_id );
    return $c->render(
        status => 404,
        format => 'json',
        json   => { error => 'TERM', description => 'No Square device_id mapped for this register' }
    ) unless $device_id;

    my $idempotency_key = _uuid();

    my $payload = {
        idempotency_key => $idempotency_key,
        checkout => {
            amount_money => {
                amount   => 0 + $amount_cents,
                currency => $cur,
            },
            device_options => {
                device_id => $device_id,
            },
            note => "Koha POS payment",
            reference_id => "pos-register-$register_id",
        }
    };

    my $res = _square_request(
        token          => $token,
        square_version => $square_version,
        environment    => $environment,
        method         => 'POST',
        path           => '/v2/terminals/checkouts',
        payload        => $payload,
    );

    return $c->render(
        status => $res->{status},
        format => 'json',
        json   => $res->{json} // { error => 'SQUARE', description => $res->{error} // 'Unknown error' }
    ) unless $res->{ok};

    my $checkout = $res->{json}->{checkout};
    return $c->render(
        status => 200,
        format => 'json',
        json   => {
            checkout_id     => $checkout->{id},
            status          => $checkout->{status},
            idempotency_key => $idempotency_key,
            amount_cents    => 0 + $amount_cents,
            register_id     => 0 + $register_id,
        }
    );
}

=head2 get_checkout

Poll status of a Square Terminal checkout
=cut

sub get_checkout {
    warn "Koha::Plugin::Com::ByWaterSolutions::SquareTerminal::API::get_checkout";
    my $c = shift->openapi->valid_input or return;

    my $checkout_id = $c->param('checkout_id') // '';
    return $c->render(
        status => 400, format => 'json',
        json   => { error => 'BAD_REQUEST', description => 'checkout_id required' }
    ) unless $checkout_id;

    my $self   = Koha::Plugin::Com::ByWaterSolutions::SquareTerminal->new({});
    my $token  = $self->retrieve_data('SquareAccessToken') // '';
    my $square_version = $self->retrieve_data('SquareVersion') // '2025-01-23';
    my $environment = $self->retrieve_data('SquareEnvironment') // 'sandbox';

    return $c->render(
        status => 500, format => 'json',
        json   => { error => 'CONFIG', description => 'SquareAccessToken not configured' }
    ) unless $token;

    my $res = _square_request(
        token          => $token,
        square_version => $square_version,
        environment    => $environment,
        method         => 'GET',
        path           => "/v2/terminals/checkouts/$checkout_id",
    );

    return $c->render(
        status => $res->{status},
        format => 'json',
        json   => $res->{json} // { error => 'SQUARE', description => $res->{error} // 'Unknown error' }
    ) unless $res->{ok};

    return $c->render(
        status => 200,
        format => 'json',
        json   => $res->{json}
    );
}

=head2 dismiss_checkout

Dismiss a checkout on the terminal display (useful after cancel/fail/success)
=cut

sub dismiss_checkout {
    warn "Koha::Plugin::Com::ByWaterSolutions::SquareTerminal::API::dismiss_checkout";
    my $c = shift->openapi->valid_input or return;

    my $checkout_id = $c->param('checkout_id') // '';
    return $c->render(
        status => 400, format => 'json',
        json   => { error => 'BAD_REQUEST', description => 'checkout_id required' }
    ) unless $checkout_id;

    my $self   = Koha::Plugin::Com::ByWaterSolutions::SquareTerminal->new({});
    my $token  = $self->retrieve_data('SquareAccessToken') // '';
    my $square_version = $self->retrieve_data('SquareVersion') // '2025-01-23';
    my $environment = $self->retrieve_data('SquareEnvironment') // 'sandbox';

    return $c->render(
        status => 500, format => 'json',
        json   => { error => 'CONFIG', description => 'SquareAccessToken not configured' }
    ) unless $token;

    my $res = _square_request(
        token          => $token,
        square_version => $square_version,
        environment    => $environment,
        method         => 'POST',
        path           => "/v2/terminals/checkouts/$checkout_id/dismiss",
        payload        => {},
    );

    return $c->render(
        status => $res->{status},
        format => 'json',
        json   => $res->{json} // { error => 'SQUARE', description => $res->{error} // 'Unknown error' }
    ) unless $res->{ok};

    return $c->render( status => 200, format => 'json', json => $res->{json} );
}

=head2 finalize_checkout

Creates a Koha payment for selected accountlines *after* Square checkout is COMPLETED.
This is a temporary endpoint that can be called by UI polling.

Later: move this logic to webhook handler for server-side completion.
=cut

sub finalize_checkout {
    warn "Koha::Plugin::Com::ByWaterSolutions::SquareTerminal::API::finalize_checkout";
    my $c = shift->openapi->valid_input or return;

    my $checkout_id     = $c->param('checkout_id') // '';
    my $accountline_ids = $c->param('accountlines') // '';
    my @ids = grep { $_ =~ /^\d+$/ } split( /,/, $accountline_ids );

    return $c->render(
        status => 400, format => 'json',
        json   => { error => 'BAD_REQUEST', description => 'checkout_id and accountlines required' }
    ) unless $checkout_id && @ids;

    my @accountlines = Koha::Account::Lines->search( { accountlines_id => \@ids } )->as_list;

    my $self   = Koha::Plugin::Com::ByWaterSolutions::SquareTerminal->new({});
    my $token  = $self->retrieve_data('SquareAccessToken') // '';
    my $square_version = $self->retrieve_data('SquareVersion') // '2025-01-23';
    my $environment = $self->retrieve_data('SquareEnvironment') // 'sandbox';

    return $c->render(
        status => 500, format => 'json',
        json   => { error => 'CONFIG', description => 'SquareAccessToken not configured' }
    ) unless $token;

    # Fetch checkout to confirm status/payment id
    my $res = _square_request(
        token          => $token,
        square_version => $square_version,
        environment    => $environment,
        method         => 'GET',
        path           => "/v2/terminals/checkouts/$checkout_id",
    );

    return $c->render(
        status => $res->{status},
        format => 'json',
        json   => $res->{json} // { error => 'SQUARE', description => $res->{error} // 'Unknown error' }
    ) unless $res->{ok};

    my $checkout = $res->{json}->{checkout} || {};
    my $status   = $checkout->{status} || '';

    return $c->render(
        status => 409, format => 'json',
        json   => { error => 'NOT_COMPLETE', description => "Checkout status is $status", checkout => $checkout }
    ) unless $status eq 'COMPLETED';

    my $payment_id = $checkout->{payment_ids} && ref($checkout->{payment_ids}) eq 'ARRAY'
        ? $checkout->{payment_ids}->[0]
        : undef;

    my $note = $payment_id ? "Square payment_id: $payment_id" : "Square checkout_id: $checkout_id";

    # Idempotency guard: check if this Square payment has already been finalized
    my $existing_payment = Koha::Account::Lines->search(
        {
            credit_type_code => 'PAYMENT',
            note             => $note,
        }
    )->next;

    if ($existing_payment) {
        return $c->render(
            status => 200,
            format => 'json',
            json   => {
                ret               => 0,
                payment_id        => $existing_payment->accountlines_id,
                checkout_id       => $checkout_id,
                square_payment_id => $payment_id,
                idempotent        => 1,
            }
        );
    }

    my $payment_res = _square_request(
    token          => $token,
    square_version => $square_version,
    environment    => $environment,
    method         => 'GET',
    path           => "/v2/payments/$payment_id",
);

return $c->render(
    status => $payment_res->{status},
    format => 'json',
    json   => $payment_res->{json}
        // {
            error       => 'SQUARE',
            description => $payment_res->{error}
                // 'Unable to retrieve Square payment',
        }
) unless $payment_res->{ok};

my $payment = $payment_res->{json}->{payment} || {};

return $c->render(
    status => 409,
    format => 'json',
    json   => {
        error       => 'PAYMENT_NOT_COMPLETE',
        description => 'Square payment is not completed',
    }
) unless ( $payment->{status} // '' ) eq 'COMPLETED';


my $amount_money = $payment->{amount_money};

return $c->render(
    status => 409,
    format => 'json',
    json   => {
        error       => 'INVALID_PAYMENT_AMOUNT',
        description => 'Square payment amount information is unavailable',
    }
) unless $amount_money
    && ref($amount_money) eq 'HASH';

my $square_amount_cents = $amount_money->{amount};

return $c->render(
    status => 409,
    format => 'json',
    json   => {
        error       => 'INVALID_PAYMENT_AMOUNT',
        description => 'Square payment amount is unavailable',
    }
) unless defined $square_amount_cents
    && $square_amount_cents =~ /^\d+$/
    && $square_amount_cents > 0;

my $amount = sprintf '%.2f', $square_amount_cents / 100;

my $userenv = C4::Context->userenv;

return $c->render(
    status => 401,
    format => 'json',
    json   => {
        error       => 'NO_STAFF_SESSION',
        description => 'The Koha staff session is unavailable during payment finalization',
    }
) unless $userenv
    && ref($userenv) eq 'HASH'
    && $userenv->{branch};

my $patron_id = $accountlines[0]->borrowernumber;

my $d = Koha::Account->new(
    { patron_id => $patron_id }
)->pay(
    {
        amount       => $amount,
        note         => $note,
        description  => 'Payment via Square Terminal',
        library_id   => $userenv->{branch},
        lines        => \@accountlines,
        payment_type => 'CREDITCARD',
    }
);

return $c->render(
    status => 500,
    format => 'json',
    json   => {
        error       => 'KOHA_PAYMENT_FAILED',
        description => 'Koha did not return payment information',
    }
) unless $d && ref($d) eq 'HASH';

    return $c->render(
        status => 200,
        format => 'json',
        json   => {
            ret        => 0,
            payment_id => $d->{payment_id},
            checkout_id=> $checkout_id,
            square_payment_id => $payment_id,
        }
    );
}

=head2 webhook

Receives and validates Square Terminal webhook notifications.

Square signs the exact notification URL concatenated with the raw HTTP
request body. The signature is supplied in the
x-square-hmacsha256-signature request header.

=cut

sub webhook {
    my $c = shift;

    my $plugin =
        Koha::Plugin::Com::ByWaterSolutions::SquareTerminal->new( {} );

    my $signature_key =
        $plugin->retrieve_data('WebhookSignatureKey') // '';

    my $notification_url =
        $plugin->retrieve_data('WebhookUrl') // '';

    return $c->render(
        status => 500,
        format => 'json',
        json   => {
            error       => 'CONFIG',
            description => 'WebhookSignatureKey is not configured',
        }
    ) unless $signature_key;

    return $c->render(
        status => 500,
        format => 'json',
        json   => {
            error       => 'CONFIG',
            description => 'WebhookUrl is not configured',
        }
    ) unless $notification_url;

    my $square_signature =
        $c->req->headers->header('x-square-hmacsha256-signature') // '';

    return $c->render(
        status => 401,
        format => 'json',
        json   => {
            error       => 'INVALID_SIGNATURE',
            description => 'Square webhook signature header is missing',
        }
    ) unless $square_signature;

    # It is important to use the untouched/raw request body here.
    my $raw_body = $c->req->body // '';

    my $expected_signature = encode_base64(
        hmac_sha256(
            $notification_url . $raw_body,
            $signature_key
        ),
        ''
    );

    unless ( _secure_compare( $expected_signature, $square_signature ) ) {
        warn sprintf(
            "Square Terminal webhook signature validation failed for URL %s",
            $notification_url
        );

        return $c->render(
            status => 401,
            format => 'json',
            json   => {
                error       => 'INVALID_SIGNATURE',
                description => 'Square webhook signature validation failed',
            }
        );
    }

    my $event;

    try {
        $event = decode_json($raw_body);
    }
    catch {
        warn "Unable to decode Square webhook JSON: $_";

        return $c->render(
            status => 400,
            format => 'json',
            json   => {
                error       => 'INVALID_PAYLOAD',
                description => 'Webhook body is not valid JSON',
            }
        );
    };

    my $event_id   = $event->{event_id} // '';
    my $event_type = $event->{type}     // '';

    my $checkout =
           $event->{data}
        && $event->{data}->{object}
        && $event->{data}->{object}->{checkout}
        ? $event->{data}->{object}->{checkout}
        : {};

    my $checkout_id = $checkout->{id}           // '';
    my $status      = $checkout->{status}       // '';
    my $reference   = $checkout->{reference_id} // '';

    warn sprintf(
        'Square Terminal webhook received: event_id=%s type=%s checkout_id=%s status=%s reference_id=%s',
        $event_id,
        $event_type,
        $checkout_id,
        $status,
        $reference,
    );

    if (
           $event_type eq 'terminal.checkout.created'
        || $event_type eq 'terminal.checkout.updated'
      )
    {
        _handle_terminal_checkout_event(
            plugin      => $plugin,
            event       => $event,
            checkout    => $checkout,
            event_id    => $event_id,
            event_type  => $event_type,
            checkout_id => $checkout_id,
            status      => $status,
            reference   => $reference,
        );
    }

    # Square expects a successful 2xx response promptly.
    return $c->render(
        status => 200,
        format => 'json',
        json   => {
            received => true,
        }
    );
}

# ---------------------------
# Helpers
# ---------------------------

sub _device_id_for_register {
    my ( $plugin, $register_id ) = @_;

    my $yaml = $plugin->retrieve_data('RegisterMapping') // '';
    my $mapping = {};
    try {
        $mapping = $yaml ? Load($yaml) : {};
    } catch {
        warn "RegisterMapping YAML parse error: $_";
        $mapping = {};
    };

    $register_id //= C4::Context->userenv->{register_id};
    return unless $register_id;

    return $mapping->{$register_id};
}

sub _square_request {
    my (%args) = @_;

    my $token          = $args{token};
    my $square_version = $args{square_version} || '2025-01-23';
    my $environment    = $args{environment} || 'sandbox';
    my $method         = $args{method} || 'GET';
    my $path           = $args{path} || '/';
    my $payload        = $args{payload};

    my $base;

    if ( $environment eq 'production' ) {
        $base = 'https://connect.squareup.com';
    }
    elsif ( $environment eq 'sandbox' ) {
        $base = 'https://connect.squareupsandbox.com';
    }
    else {
        return {
            ok     => 0,
            status => 500,
            error  => "Invalid SquareEnvironment value: $environment",
            json   => {
                error       => 'CONFIG',
                description => 'SquareEnvironment must be sandbox or production',
            },
        };
    }

    my $url  = $base . $path;

    my $ua = LWP::UserAgent->new( timeout => 30 );

    my $req;
    if ( $method eq 'POST' ) {
        my $body = encode_json( $payload // {} );
        $req = HTTP::Request->new( 'POST', $url );
        $req->header( 'Authorization'  => "Bearer $token" );
        $req->header( 'Content-Type'   => 'application/json' );
        $req->header( 'Accept'         => 'application/json' );
        $req->header( 'Square-Version' => $square_version );
        $req->content($body);
    } else {
        $req = HTTP::Request->new( 'GET', $url );
        $req->header( 'Authorization'  => "Bearer $token" );
        $req->header( 'Content-Type'   => 'application/json' );
        $req->header( 'Accept'         => 'application/json' );
        $req->header( 'Square-Version' => $square_version );
    }

    my $resp = $ua->request($req);

    my $out = {
        ok     => 0,
        status => $resp->code,
    };

    my $content = $resp->decoded_content // '';

    my $json;
    try {
        $json = $content ? decode_json($content) : {};
    } catch {
        $json = undef;
        $out->{error} = "Non-JSON response from Square: $content";
    };

    $out->{json} = $json if defined $json;

    if ( $resp->is_success ) {
        $out->{ok} = 1;
        return $out;
    }

    if ( $json && $json->{errors} ) {
        $out->{error} = $json->{errors}->[0]->{detail} // $json->{errors}->[0]->{code};
    } else {
        $out->{error} ||= $resp->status_line;
    }

    return $out;
}

sub _uuid {
    my $uuid = '';
    for ( 1 .. 4 ) {
        $uuid .= pack 'I', int( rand( 2**32 ) );
    }
    substr $uuid, 6, 1, chr( ord( substr( $uuid, 6, 1 ) ) & 0x0f | 0x40 );
    return join '', map { unpack 'H*', $_ }
      map { substr $uuid, 0, $_, '' } ( 4, 2, 2, 2, 6 );
}

sub _secure_compare {
    my ( $expected, $received ) = @_;

    return 0 unless defined $expected && defined $received;
    return 0 unless length($expected) == length($received);

    my $difference = 0;

    for my $index ( 0 .. length($expected) - 1 ) {
        $difference |=
            ord( substr( $expected, $index, 1 ) )
          ^ ord( substr( $received, $index, 1 ) );
    }

    return $difference == 0;
}

sub _handle_terminal_checkout_event {
    my (%args) = @_;

    my $event_type  = $args{event_type}  // '';
    my $event_id    = $args{event_id}    // '';
    my $checkout_id = $args{checkout_id} // '';
    my $status      = $args{status}      // '';
    my $reference   = $args{reference}   // '';

    return unless $checkout_id;

    if ( $status eq 'COMPLETED' ) {
        warn sprintf(
            'Square Terminal checkout completed: event_id=%s checkout_id=%s reference_id=%s',
            $event_id,
            $checkout_id,
            $reference,
        );

        # Do not create the Koha payment here yet.
        #
        # The current browser flow calls finalize_checkout after polling
        # detects COMPLETED. Creating the payment here as well would risk
        # recording the same Square payment twice.
    }
    elsif ( $status eq 'CANCELED' || $status eq 'CANCELLED' ) {
        warn sprintf(
            'Square Terminal checkout canceled: event_id=%s checkout_id=%s',
            $event_id,
            $checkout_id,
        );
    }
    elsif ( $status eq 'FAILED' ) {
        warn sprintf(
            'Square Terminal checkout failed: event_id=%s checkout_id=%s',
            $event_id,
            $checkout_id,
        );
    }

    return;
}

1;
