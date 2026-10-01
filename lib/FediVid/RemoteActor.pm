package FediVid::RemoteActor;
use Mojo::Base -strict, -signatures;
use Mojo::JSON qw(encode_json decode_json);
use FediVid::URLGuard qw(check_url);

my $TTL = 24 * 3600;

sub fetch ($ua, $db, $key_id) {
    (my $actor_url = $key_id) =~ s/#.*\z//;

    # --- Cache first ---
    my $cached = $db->query(
        q{SELECT actor, public_key, fetched_at
            FROM remote_actors
           WHERE url = ?
             AND fetched_at > NOW() - make_interval(secs => ?)},
        $actor_url, $TTL
    )->hash;

    if ($cached) {
        my $actor = decode_json($cached->{actor});

        # Verify the cached actor's id matches the URL it is stored under.
        my $cached_id = $actor->{id} // '';
        (my $cached_id_clean = $cached_id) =~ s/#.*\z//;
        if ($cached_id_clean ne $actor_url) {
            # Poisoned cache entry — drop it and fall through to re-fetch.
            $db->query('DELETE FROM remote_actors WHERE url = ?', $actor_url);
        } else {
            return ({
                %$actor,
                publicKey => {
                    %{ $actor->{publicKey} },
                    publicKeyPem => $cached->{public_key},
                },
            }, undef);
        }
    }

    # --- URL guard only on network path ---
    my $allow_insecure = $ENV{FEDIVID_ALLOW_INSECURE_FETCH} // 0;
    my ($ok, $err) = check_url(
        $actor_url,
        allow_insecure => $allow_insecure,
        allow_private  => $allow_insecure,
    );
    return (undef, "URL rejected: $err") unless $ok;

    # --- Fetch ---
    my $tx = $ua->get(
        $actor_url => {
            'Accept'     => 'application/activity+json, application/ld+json',
            'User-Agent' => 'FediVid/0.1 (+http://localhost:3000)',
        }
    );

    my $res = $tx->res;
    return (undef, 'no response from remote') unless $res;

    my $code = $res->code // 0;
    return (undef, "remote returned $code") unless $code == 200;

    my $actor = $res->json;
    return (undef, 'remote returned non-JSON') unless $actor;
    return (undef, 'actor document is not a hash') unless ref $actor eq 'HASH';

    # Verify the document's id matches the URL we fetched it from.
    my $actor_id = $actor->{id} // '';
    (my $actor_id_clean = $actor_id) =~ s/#.*\z//;
    return (undef, "actor id mismatch: fetched from $actor_url but id is $actor_id")
        if $actor_id_clean ne $actor_url;

    my $pk = $actor->{publicKey};
    return (undef, 'actor has no publicKey') unless $pk;
    return (undef, 'publicKey has no publicKeyPem') unless $pk->{publicKeyPem};

    my $public_pem = $pk->{publicKeyPem};

    $db->query(
        'INSERT INTO remote_actors (url, actor, public_key, fetched_at)
              VALUES (?, ?, ?, NOW())
         ON CONFLICT (url)
         DO UPDATE SET
             actor      = EXCLUDED.actor,
             public_key = EXCLUDED.public_key,
             fetched_at = NOW()',
        $actor_url, encode_json($actor), $public_pem
    );

    return ($actor, undef);
}

1;
