package FediVid::Controller::Actor;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Mojo::JSON qw(encode_json decode_json);
use FediVid::Signature qw(verify_request verify_digest);
use FediVid::RemoteActor;
use FediVid::ActivityHandler;

sub show ($c) {
    my $accept = $c->req->headers->header('Accept') // '';

    # Serve the SPA only when the client explicitly prefers HTML.
    # `*/*` and missing Accept default to the federation JSON.
    if ($accept =~ m{text/html} && $accept !~ m{application/(activity\+json|ld\+json)}) {
        return $c->reply->static('index.html');
    }

    my $username = $c->param('username');
    my $db       = $c->pg->db;

    my $user = $db->query(
        'SELECT id, username, created_at, public_key_pem, avatar_path
           FROM users WHERE username = ?',
        $username
    )->hash;

    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $user;

    my $base     = $c->config('scheme') . '://' . $c->config('domain');
    my $actor_id = "$base/users/$username";

    my $actor = {
        '@context' => [
            'https://www.w3.org/ns/activitystreams',
            'https://w3id.org/security/v1',
        ],
        id                => $actor_id,
        type              => 'Person',
        preferredUsername => $username,
        name              => $username,
        published         => $user->{created_at},
        inbox             => "$actor_id/inbox",
        outbox            => "$actor_id/outbox",
        followers         => "$actor_id/followers",
        following         => "$actor_id/following",
    };

    if ($user->{avatar_path}) {
        $actor->{icon} = {
            type => 'Image',
            url  => "$base/users/$username/avatar",
        };
    }

    if ($user->{public_key_pem}) {
        $actor->{publicKey} = {
            id           => "$actor_id#main-key",
            owner        => $actor_id,
            publicKeyPem => $user->{public_key_pem},
        };
    }

    $c->res->headers->content_type('application/activity+json');
    $c->render(data => encode_json($actor));
}

sub outbox ($c) {
    my $username = $c->param('username');
    my $db       = $c->pg->db;

    my $exists = $db->query(
        'SELECT 1 FROM users WHERE username = ?', $username
    )->array;
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $exists;

    my $base = $c->config('scheme') . '://' . $c->config('domain');

    my $rows = $db->query(
        "SELECT activity FROM outbox_activities
          WHERE username = ?
            AND activity->>'type' = 'Create'
          ORDER BY published_at DESC
          LIMIT 50",
        $username
    )->hashes;

    my @items = map { decode_json($_->{activity}) } @$rows;

    $c->res->headers->content_type('application/activity+json');
    $c->render(data => encode_json({
        '@context'     => 'https://www.w3.org/ns/activitystreams',
        id             => "$base/users/$username/outbox",
        type           => 'OrderedCollection',
        totalItems     => scalar @items,
        orderedItems   => \@items,
    }));
}

sub inbox ($c) {
    my $username = $c->param('username');
    my $db       = $c->pg->db;

    my $exists = $db->query(
        'SELECT 1 FROM users WHERE username = ?', $username
    )->array;
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $exists;

    unless ($ENV{FEDIVID_RATE_LIMIT_DISABLED}) {
        my $ip = $c->tx->remote_address // 'unknown';
        require FediVid::RateLimit;
        my ($allowed, $retry_in) = FediVid::RateLimit::check_rate(
            $db, "inbox:$ip", 60, 60
        );
        unless ($allowed) {
            $c->res->headers->header('Retry-After' => $retry_in);
            return $c->render(json => {
                error       => 'rate_limited',
                retry_after => $retry_in,
            }, status => 429);
        }
    }

    my $auth = $c->req->headers->header('Authorization') // '';
    my ($remote_key_id) = $auth =~ /keyId="([^"]+)"/;
    return $c->render(json => { error => 'missing_signature' }, status => 401)
        unless $remote_key_id;

    my ($actor, $fetch_err) =
        FediVid::RemoteActor::fetch($c->ua, $db, $remote_key_id);
    return $c->render(
        json   => { error => 'cannot_fetch_actor', detail => $fetch_err },
        status => 401,
    ) unless $actor;

    my $public_pem = $actor->{publicKey}{publicKeyPem};

    my ($sig_ok, $sig_err) = verify_request($c->req, $public_pem);
    return $c->render(
        json   => { error => 'invalid_signature', detail => $sig_err },
        status => 401,
    ) unless $sig_ok;

    my ($digest_ok, $digest_err) = verify_digest($c->req);
    return $c->render(
        json   => { error => 'invalid_digest', detail => $digest_err },
        status => 401,
    ) unless $digest_ok;

    my $body = $c->req->json;
    return $c->render(json => { error => 'invalid_json' }, status => 400)
        unless $body && ref $body eq 'HASH';

    # The activity's actor must match the actor derived from the signature keyId.
    # Otherwise a valid key holder could impersonate any remote actor.
    my $claimed_actor = $body->{actor};
    return $c->render(
        json   => { error => 'missing_actor' },
        status => 400,
    ) unless defined $claimed_actor && !ref $claimed_actor;

    my $expected_actor = $actor->{id} // '';
    (my $expected_clean = $expected_actor) =~ s/#.*\z//;
    (my $claimed_clean  = $claimed_actor)  =~ s/#.*\z//;

    return $c->render(
        json   => {
            error  => 'actor_mismatch',
            detail => "activity actor '$claimed_clean' does not match key owner '$expected_clean'",
        },
        status => 401,
    ) unless $claimed_clean eq $expected_clean;

    $db->query(
        'INSERT INTO activities (username, activity) VALUES (?, ?)',
        $username, encode_json($body)
    );

    my $user = $db->query(
        'SELECT private_key_pem FROM users WHERE username = ?', $username
    )->hash;

    my $base         = $c->config('scheme') . '://' . $c->config('domain');
    my $local_key_id = "$base/users/$username#main-key";

    my ($handled, $handle_err) = FediVid::ActivityHandler::handle(
        $c->ua, $db, $c->config, $username, $body,
        $user->{private_key_pem}, $local_key_id,
    );

    if (!$handled) {
        $c->app->log->warn("activity rejected: $handle_err");
    }

    $c->res->headers->content_type('application/activity+json');
    $c->render(json => { status => 'accepted' }, status => 202);
}

1;
