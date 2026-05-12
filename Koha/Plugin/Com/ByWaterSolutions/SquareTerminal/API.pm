package Koha::Plugin::Com::ByWaterSolutions::SquareTerminal::API;

use Modern::Perl;
use Mojo::Base 'Mojolicious::Controller';

use HTTP::Headers;
use HTTP::Request::Common qw( GET POST );
use LWP::UserAgent;
use Mojo::JSON qw( encode_json decode_json );
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

    return $c->render(
        status => 400, format => 'json',
        json   => { error => 'BAD_REQUEST', description => 'Amount must be > 0' }
    ) unless $amount_cents > 0;

    my $self   = Koha::Plugin::Com::ByWaterSolutions::SquareTerminal->new({});
    my $token  = $self->retrieve_data('SquareAccessToken') // '';
    my $cur    = $self->retrieve_data('Currency') // 'USD';
    my $square_version = $self->retrieve_data('SquareVersion') // '2025-01-23';

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

    return $c->render(
        status => 500, format => 'json',
        json   => { error => 'CONFIG', description => 'SquareAccessToken not configured' }
    ) unless $token;

    my $res = _square_request(
        token          => $token,
        square_version => $square_version,
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

    return $c->render(
        status => 500, format => 'json',
        json   => { error => 'CONFIG', description => 'SquareAccessToken not configured' }
    ) unless $token;

    my $res = _square_request(
        token          => $token,
        square_version => $square_version,
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

    return $c->render(
        status => 500, format => 'json',
        json   => { error => 'CONFIG', description => 'SquareAccessToken not configured' }
    ) unless $token;

    # Fetch checkout to confirm status/payment id
    my $res = _square_request(
        token          => $token,
        square_version => $square_version,
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

    my $amount = 0;
    $amount += $_->amountoutstanding for @accountlines;
    $amount = sprintf("%.2f", $amount);

    my $patron_id = $accountlines[0]->borrowernumber;
    my $d = Koha::Account->new({ patron_id => $patron_id })->pay({
        amount       => $amount,
        note         => $note,
        description  => "Payment via Square Terminal",
        library_id   => C4::Context->userenv->{branch},
        lines        => \@accountlines,
        payment_type => "CREDITCARD",
    });

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
    my $method         = $args{method} || 'GET';
    my $path           = $args{path} || '/';
    my $payload        = $args{payload};

    my $base = 'https://connect.squareupsandbox.com';
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

1;
