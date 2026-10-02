package FediVid::Controller::Following;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Mojo::JSON qw(encode_json);
use Mojo::Util qw(trim);
use FediVid::Signature qw(verify_request verify_digest);
use FediVid::RemoteActor;
use FediVid::WebFinger qw(resolve_handle);

sub create ($c) {
    my $username = $c->param('username');
    my $db       = $c->pg->db;

    my $user = $db->query(
        'SELECT private_key_pem, public_key_pem FROM users WHERE username = ?',
        $username
    )->hash;
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $user;

    my ($authed, $auth_err) = _authenticate_as($c, $user);
    return $c->render(json => {
        error  => 'unauthorized',
        detail => $auth_err,
    }, status => 401) unless $authed;

    my $body   = $c->req->json // {};
    my $target = trim($body->{actor} // '');
    return $c->render(json => { error => 'missing_actor' }, status => 400)
        unless length $target;

    my $base     = $c->config('base_url');
    my $expected = "$base/users/$username";
    return $c->render(json => { error => 'cannot_follow_self' }, status => 400)
        if $target eq $expected;

    my ($actor_url, $norm_err) = _normalize_recipient($c, $target);
    return $c->render(json => {
        error  => 'invalid_target',
        detail => $norm_err,
    }, status => 400) unless $actor_url;

    # Local target?
    my ($local_target) = $actor_url =~ m{\A\Q$base\E/users/([^/]+)\z};

    if ($local_target) {
        my $exists = $db->query(
            'SELECT 1 FROM users WHERE username = ?', $local_target
        )->array;
        return $c->render(json => { error => 'target_not_found' }, status => 404)
            unless $exists;

        my $existing = $db->query(
            'SELECT 1 FROM following WHERE local_user = ? AND remote_actor = ?',
            $username, $actor_url
        )->array;
        return $c->render(json => { error => 'already_following' }, status => 409)
            if $existing;

        $db->query(
            'INSERT INTO followers (local_user, remote_actor, remote_inbox, accepted)
                  VALUES (?, ?, NULL, TRUE)
             ON CONFLICT (local_user, remote_actor) DO NOTHING',
            $local_target, "$base/users/$username"
        );

        $db->query(
            'INSERT INTO following (local_user, remote_actor, remote_inbox, accepted)
                  VALUES (?, ?, NULL, TRUE)
             ON CONFLICT (local_user, remote_actor) DO NOTHING',
            $username, $actor_url
        );

        require FediVid::Notifications;
        FediVid::Notifications::notify(
            $db, $local_target, 'follow', "$base/users/$username", undef, undef
        );

        return $c->render(json => {
            type   => 'Follow',
            object => $actor_url,
            status => 'accepted',
        });
    }

    # Remote target
    my ($remote, $fetch_err) = FediVid::RemoteActor::fetch($c->ua, $db, $actor_url);
    return $c->render(json => {
        error  => 'cannot_fetch_actor',
        detail => $fetch_err,
    }, status => 502) unless $remote;

    my $inbox = $remote->{inbox};
    return $c->render(json => { error => 'remote_has_no_inbox' }, status => 502)
        unless $inbox;

    my $remote_actor_url = $remote->{id} // $actor_url;

    my $existing = $db->query(
        'SELECT activity_id, accepted FROM following
          WHERE local_user = ? AND remote_actor = ?',
        $username, $remote_actor_url
    )->hash;
    return $c->render(json => {
        error    => 'already_following',
        accepted => $existing->{accepted} ? 1 : 0,
    }, status => 409) if $existing;

    my $activity_id = "$base/users/$username#follows/" . time . '-' . int(rand(10000));

    my $follow = {
        '@context' => 'https://www.w3.org/ns/activitystreams',
        id         => $activity_id,
        type       => 'Follow',
        actor      => "$base/users/$username",
        object     => $remote_actor_url,
    };

    $db->query(
        'INSERT INTO following (local_user, remote_actor, remote_inbox, activity_id)
              VALUES (?, ?, ?, ?)
         ON CONFLICT (local_user, remote_actor) DO NOTHING',
        $username, $remote_actor_url, $inbox, $activity_id
    );

    my $key_id = "$base/users/$username#main-key";

    require FediVid::DeliveryQueue;
    FediVid::DeliveryQueue::enqueue($db, $username, $inbox, $follow);

    # Backfill only if we've never seen this actor before
    my $already_known = $db->query(
        'SELECT 1 FROM remote_videos WHERE remote_actor = ? LIMIT 1',
        $remote_actor_url
    )->array;

    _backfill_actor($c, $db, $username, $remote_actor_url) unless $already_known;

    $c->res->headers->content_type('application/activity+json');
    $c->render(
        status => 202,
        data   => encode_json({
            type   => 'Follow',
            id     => $activity_id,
            actor  => "$base/users/$username",
            object => $remote_actor_url,
            status => 'pending',
        }),
    );
}

sub remove ($c) {
    my $username = $c->param('username');
    my $db       = $c->pg->db;

    my $user = $db->query(
        'SELECT private_key_pem, public_key_pem FROM users WHERE username = ?',
        $username
    )->hash;
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $user;

    my ($authed, $auth_err) = _authenticate_as($c, $user);
    return $c->render(json => {
        error  => 'unauthorized',
        detail => $auth_err,
    }, status => 401) unless $authed;

    my $body   = $c->req->json // {};
    my $target = trim($body->{actor} // '');
    return $c->render(json => { error => 'missing_actor' }, status => 400)
        unless length $target;

    my $base = $c->config('base_url');

    my ($actor_url, $norm_err) = _normalize_recipient($c, $target);
    return $c->render(json => {
        error  => 'invalid_target',
        detail => $norm_err,
    }, status => 400) unless $actor_url;

    my ($local_target) = $actor_url =~ m{\A\Q$base\E/users/([^/]+)\z};
    if ($local_target) {
        $db->query(
            'DELETE FROM followers WHERE local_user = ? AND remote_actor = ?',
            $local_target, "$base/users/$username"
        );
        $db->query(
            'DELETE FROM following WHERE local_user = ? AND remote_actor = ?',
            $username, $actor_url
        );
        return $c->render(json => { ok => 1 });
    }

    my $row = $db->query(
        'SELECT remote_inbox, activity_id FROM following
          WHERE local_user = ? AND remote_actor = ?',
        $username, $actor_url
    )->hash;
    return $c->render(json => { error => 'not_following' }, status => 404)
        unless $row;

    $db->query(
        'DELETE FROM following WHERE local_user = ? AND remote_actor = ?',
        $username, $actor_url
    );

    # Remove cached remote videos so they disappear from the user's federated feed
    $db->query(
        'DELETE FROM remote_videos WHERE local_user = ? AND remote_actor = ?',
        $username, $actor_url
    );

    if ($row->{remote_inbox}) {
        my $undo = {
            '@context' => 'https://www.w3.org/ns/activitystreams',
            id         => "$base/users/$username#undos/" . time . '-' . int(rand(10000)),
            type       => 'Undo',
            actor      => "$base/users/$username",
            object     => {
                id     => $row->{activity_id},
                type   => 'Follow',
                actor  => "$base/users/$username",
                object => $actor_url,
            },
        };

        require FediVid::DeliveryQueue;
        FediVid::DeliveryQueue::enqueue($db, $username, $row->{remote_inbox}, $undo);
    }

    $c->render(json => { ok => 1 });
}

sub index ($c) {
    my $username = $c->param('username');
    my $db       = $c->pg->db;

    my $exists = $db->query(
        'SELECT 1 FROM users WHERE username = ?', $username
    )->array;
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $exists;

    my $rows = $db->query(
        'SELECT remote_actor, accepted, created_at
           FROM following
          WHERE local_user = ?
          ORDER BY created_at DESC
          LIMIT 100',
        $username
    )->hashes;

    $c->render(json => {
        totalItems => scalar @$rows,
        items      => $rows,
    });
}

sub _backfill_actor ($c, $db, $username, $actor_url) {
    require FediVid::Outbox;
    require FediVid::ActivityHandler;

    my $activities = eval {
        FediVid::Outbox::fetch_recent_videos($c->ua, $actor_url, 20);
    } // [];

    my $config = $c->config;
    my $count = 0;

    for my $act (@$activities) {
        my $ok = eval {
            FediVid::ActivityHandler::handle(
                $c->ua, $db, $config,
                $username, $act,
                undef, undef,
                { skip_notifications => 1 },
            );
            1;
        };
        $count++ if $ok;
    }

    $c->app->log->info("backfilled $count video(s) from $actor_url for $username");

    return $count;
}

sub _normalize_recipient ($c, $to) {
    my $base = $c->config('base_url');

    # Local username
    if ($to =~ m{\A[a-z0-9_]{3,30}\z}) {
        return ("$base/users/$to", undef);
    }

    # Actor URL
    if ($to =~ m{\Ahttps?://}) {
        return ($to, undef);
    }

    # Handle @user@host[:port]
    if ($to =~ m{\A\@[a-z0-9_]+@[a-z0-9.\-]+(?::\d+)?\z}i) {
        my $url = resolve_handle($c->ua, $to);
        return ($url, undef) if $url;
        return (undef, 'webfinger resolution failed');
    }

    return (undef, 'unrecognized recipient format');
}

sub _authenticate_as ($c, $user) {
    my $username = $c->param('username');

    my $session_user = eval {
        require FediVid::Controller::Sessions;
        FediVid::Controller::Sessions::_current_user($c);
    };
    return (1, undef) if $session_user && $session_user eq $username;

    return (0, 'user has no public key') unless $user->{public_key_pem};

    my $auth = $c->req->headers->header('Authorization') // '';
    return (0, 'missing Authorization header') unless $auth;

    my ($key_id) = $auth =~ /keyId="([^"]+)"/;
    return (0, 'missing keyId') unless $key_id;

    my $base   = $c->config('base_url');
    my $expect = "$base/users/$username";

    (my $key_actor = $key_id) =~ s/#.*\z//;
    return (0, 'keyId does not match user') unless $key_actor eq $expect;

    my ($sig_ok, $sig_err) = verify_request($c->req, $user->{public_key_pem});
    return (0, "signature: $sig_err") unless $sig_ok;

    my ($digest_ok, $digest_err) = verify_digest($c->req);
    return (0, "digest: $digest_err") unless $digest_ok;

    return (1, undef);
}

1;
