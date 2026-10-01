package FediVid::Controller::ApiMessages;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Mojo::JSON qw(encode_json decode_json);
use Mojo::Util qw(trim);
use Mojo::URL;
use FediVid::Signature qw(verify_request verify_digest);
use FediVid::RemoteActor;
use FediVid::WebFinger qw(resolve_handle);

sub send ($c) {
    my $db = $c->pg->db;

    my $body = $c->req->json // {};
    my $from = trim($body->{from} // '');
    my $to   = trim($body->{to} // '');
    my $text = trim($body->{body} // '');

    return $c->render(json => { error => 'missing_from' }, status => 400)
        unless length $from;
    return $c->render(json => { error => 'missing_to' }, status => 400)
        unless length $to;
    return $c->render(json => { error => 'missing_body' }, status => 400)
        unless length $text;
    return $c->render(json => { error => 'too_long' }, status => 400)
        if length($text) > 5000;

    my $base = $c->config('base_url');

    # Normalize sender — must be a local user
    my $from_actor = _normalize_sender($c, $from);
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $from_actor;

    my ($from_local) = $from_actor =~ m{\A\Q$base\E/users/([^/]+)\z};
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $from_local;

    my $user = $db->query(
        'SELECT private_key_pem, public_key_pem FROM users WHERE username = ?',
        $from_local
    )->hash;
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $user;

    my ($authed, $auth_err) = _authenticate_as($c, $user, $from_local);
    return $c->render(json => {
        error  => 'unauthorized',
        detail => $auth_err,
    }, status => 401) unless $authed;

    # Normalize recipient — either local or remote
    my ($to_actor, $to_err) = _normalize_recipient($c, $to);
    return $c->render(json => { error => 'recipient_not_found', detail => $to_err },
                      status => 404) unless $to_actor;

    return $c->render(json => { error => 'cannot_message_self' }, status => 400)
        if $to_actor eq $from_actor;

    my ($to_local) = $to_actor =~ m{\A\Q$base\E/users/([^/]+)\z};

    if ($to_local) {
        my $exists = $db->query(
            'SELECT 1 FROM users WHERE username = ?', $to_local
        )->array;
        return $c->render(json => { error => 'recipient_not_found' }, status => 404)
            unless $exists;

        my $row = $db->query(
            'INSERT INTO messages (sender_actor, recipient_actor, body, is_remote)
                  VALUES (?, ?, ?, FALSE)
             RETURNING id, created_at',
            $from_actor, $to_actor, $text
        )->hash;

        return $c->render(
            status => 201,
            json   => {
                id         => $row->{id} + 0,
                sender     => $from_local,
                recipient  => $to_local,
                body       => $text,
                created_at => $row->{created_at},
                is_remote  => 0,
            },
        );
    }

    # Remote recipient
    my ($remote, $fetch_err) = FediVid::RemoteActor::fetch($c->ua, $db, $to_actor);
    return $c->render(json => {
        error  => 'cannot_fetch_actor',
        detail => $fetch_err,
    }, status => 502) unless $remote;

    my $inbox = $remote->{inbox};
    return $c->render(json => { error => 'remote_has_no_inbox' }, status => 502)
        unless $inbox;

    my $actor_url = $remote->{id} // $to_actor;

    my $activity_id = "$base/users/$from_local#notes/" . time . '-' . int(rand(1_000_000));

    my $activity = {
        '@context' => 'https://www.w3.org/ns/activitystreams',
        id         => $activity_id,
        type       => 'Create',
        actor      => $from_actor,
        to         => [$actor_url],
        object     => {
            id           => "$activity_id#object",
            type         => 'Note',
            attributedTo => $from_actor,
            to           => [$actor_url],
            content      => $text,
            mediaType    => 'text/plain',
            published    => _now_iso(),
        },
    };

    my $row = $db->query(
        'INSERT INTO messages
             (sender_actor, recipient_actor, body, activity_id, is_remote)
              VALUES (?, ?, ?, ?, TRUE)
         RETURNING id, created_at',
        $from_actor, $actor_url, $text, $activity->{object}{id}
    )->hash;

    require FediVid::DeliveryQueue;
    FediVid::DeliveryQueue::enqueue($db, $from_local, $inbox, $activity);

    $c->render(
        status => 201,
        json   => {
            id         => $row->{id} + 0,
            sender     => $from_local,
            recipient  => _short_actor($actor_url, $base),
            body       => $text,
            created_at => $row->{created_at},
            is_remote  => 1,
        },
    );
}

sub inbox ($c) {
    my $db = $c->pg->db;

    my $session_user = _require_session($c);
    return $c->render(json => { error => 'unauthenticated' }, status => 401)
        unless $session_user;

    my $base  = $c->config('base_url');
    my $actor = "$base/users/$session_user";

    my $rows = $db->query(
        'SELECT id, sender_actor, body, read_at, created_at, is_remote
           FROM messages
          WHERE recipient_actor = ? AND hidden_by_recipient = FALSE
          ORDER BY created_at DESC
          LIMIT 200',
        $actor
    )->hashes;

    my $unread = $db->query(
        'SELECT COUNT(*) AS n FROM messages
          WHERE recipient_actor = ? AND read_at IS NULL',
        $actor
    )->hash->{n};

    $c->render(json => {
        totalItems => scalar @$rows,
        unseen     => $unread + 0,
        items      => [ map {
            {
                id         => $_->{id} + 0,
                sender     => _short_actor($_->{sender_actor}, $base),
                body       => $_->{body},
                read       => $_->{read_at} ? 1 : 0,
                is_remote  => $_->{is_remote} ? 1 : 0,
                created_at => $_->{created_at},
            }
        } @$rows ],
    });
}

sub thread ($c) {
    my $db    = $c->pg->db;
    my $other = $c->param('username');

    my $session_user = _require_session($c);
    return $c->render(json => { error => 'unauthenticated' }, status => 401)
        unless $session_user;

    my $base  = $c->config('base_url');
    my $me    = "$base/users/$session_user";

    my ($other_actor) = _normalize_recipient($c, $other);
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $other_actor;

    my $rows = $db->query(
        'SELECT id, sender_actor, recipient_actor, body, read_at, created_at
           FROM messages
          WHERE (sender_actor = ? AND recipient_actor = ? AND hidden_by_sender = FALSE)
             OR (sender_actor = ? AND recipient_actor = ? AND hidden_by_recipient = FALSE)
          ORDER BY created_at ASC
          LIMIT 500',
        $me, $other_actor, $other_actor, $me
    )->hashes;

    $c->render(json => {
        totalItems => scalar @$rows,
        items      => [ map {
            {
                id         => $_->{id} + 0,
                sender     => _short_actor($_->{sender_actor}, $base),
                recipient  => $_->{recipient_actor},
                body       => $_->{body},
                created_at => $_->{created_at},
            }
        } @$rows ],
    });
}

sub thread_read ($c) {
    my $db    = $c->pg->db;
    my $other = $c->param('username');

    my $session_user = _require_session($c);
    return $c->render(json => { error => 'unauthenticated' }, status => 401)
        unless $session_user;

    my $base = $c->config('base_url');
    my $me   = "$base/users/$session_user";

    # Try several forms of the peer identifier
    my @candidates = ($other);
    push @candidates, "$base/users/$other" if $other !~ m{/};

    my ($resolved) = _normalize_recipient($c, $other);
    push @candidates, $resolved if $resolved;

    my @unique = do {
        my %seen;
        grep { !$seen{$_}++ } @candidates;
    };

    my $placeholders = join(',', ('?') x @unique);
    $db->query(
        "UPDATE messages SET read_at = NOW()
          WHERE recipient_actor = ?
            AND sender_actor IN ($placeholders)
            AND read_at IS NULL",
        $me, @unique
    );

    $c->render(json => { ok => 1 });
}

# --- helpers ---

sub _normalize_sender ($c, $from) {
    # Accept "alice" (local), an actor URL, or nothing else.
    # The sender must always be a local user.
    my $base = $c->config('base_url');

    if ($from =~ m{\A[a-z0-9_]{3,30}\z}) {
        return "$base/users/$from";
    }
    if ($from =~ m{\A\Q$base\E/users/[a-z0-9_]{3,30}\z}) {
        return $from;
    }
    return undef;
}

sub conversations ($c) {
    my $db = $c->pg->db;

    my $session_user = _require_session($c);
    return $c->render(json => { error => 'unauthenticated' }, status => 401)
        unless $session_user;

    my $base = $c->config('base_url');
    my $me   = "$base/users/$session_user";

    my $all = $db->query(
        'SELECT id, sender_actor, recipient_actor, body, read_at, created_at
           FROM messages
          WHERE (sender_actor = ? AND hidden_by_sender = FALSE)
             OR (recipient_actor = ? AND hidden_by_recipient = FALSE)
          ORDER BY created_at DESC
          LIMIT 500',
        $me, $me
    )->hashes;

    # Group by peer in Perl
    my %threads;
    for my $m (@$all) {
        my $peer = ($m->{sender_actor} eq $me)
            ? $m->{recipient_actor}
            : $m->{sender_actor};

        if (!$threads{$peer}) {
            $threads{$peer} = {
                peer       => $peer,
                last_body  => $m->{body},
                last_at    => $m->{created_at},
                unread     => 0,
            };
        }

        # Count unread: messages from peer to me that aren't read
        if ($m->{sender_actor} eq $peer
            && $m->{recipient_actor} eq $me
            && !$m->{read_at})
        {
            $threads{$peer}{unread}++;
        }
    }

    my @items = sort { $b->{last_at} cmp $a->{last_at} } values %threads;

    $c->render(json => {
        totalItems => scalar @items,
        items      => [ map {
            {
                peer       => _short_actor($_->{peer}, $base),
                peer_actor => $_->{peer},
                last_body  => $_->{last_body},
                last_at    => $_->{last_at},
                unread     => $_->{unread},
            }
        } @items ],
    });
}

sub _normalize_recipient ($c, $to) {
    my $base = $c->config('base_url');

    # Actor URL
    if ($to =~ m{\Ahttps?://}) {
        return ($to, undef);
    }

    # Handle @user@host[:port] or user@host[:port]
    if ($to =~ m{\A\@?([a-z0-9_]+)@([a-z0-9.\-]+(?::\d+)?)\z}i) {
        my $handle = "\@$1\@$2";
        my $url = resolve_handle($c->ua, $handle);
        return ($url, undef) if $url;
        return (undef, 'webfinger resolution failed');
    }

    # Bare username — try local first, then look up in known remote_actors
    if ($to =~ m{\A[a-z0-9_]{3,30}\z}) {
        my $db = $c->pg->db;

        my $local = $db->query(
            'SELECT 1 FROM users WHERE username = ?', $to
        )->array;
        return ("$base/users/$to", undef) if $local;

        # Look for a remote actor whose URL ends in /users/$to
        my $remote = $db->query(
            "SELECT url FROM remote_actors WHERE url LIKE ? LIMIT 1",
            "%/users/$to"
        )->hash;
        return ($remote->{url}, undef) if $remote;

        return (undef, 'unknown recipient');
    }

    return (undef, 'unrecognized recipient format');
}

sub _require_session ($c) {
    return eval {
        require FediVid::Controller::Sessions;
        FediVid::Controller::Sessions::_current_user($c);
    };
}

sub _authenticate_as ($c, $user, $username) {
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

sub _now_iso () {
    require POSIX;
    my @t = gmtime(time);
    return POSIX::strftime('%Y-%m-%dT%H:%M:%SZ', @t);
}

sub _short_actor ($actor, $base) {
    return '' unless defined $actor;
    if ($actor =~ m{\A\Q$base\E/users/([^/]+)\z}) {
        return $1;
    }
    if ($actor =~ m{\Ahttps?://([^/]+)/users/([^/]+)\z}) {
        return "$2\@$1";  # romeo@localhost:3001
    }
    (my $s = $actor) =~ s{\Ahttps?://}{};
    return $s;
}

sub delete_thread ($c) {
    my $db = $c->pg->db;

    my $session_user = _require_session($c);
    return $c->render(json => { error => 'unauthenticated' }, status => 401)
        unless $session_user;

    my $peer = $c->param('username');
    return $c->render(json => { error => 'invalid_peer' }, status => 400)
        unless defined $peer && length $peer;

    my ($peer_actor) = _normalize_recipient($c, $peer);
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $peer_actor;

    my $base = $c->config('base_url');
    my $me   = "$base/users/$session_user";

    # Hide messages where I'm the sender
    $db->query(
        'UPDATE messages SET hidden_by_sender = TRUE
          WHERE sender_actor = ? AND recipient_actor = ?',
        $me, $peer_actor
    );

    # Hide messages where I'm the recipient
    $db->query(
        'UPDATE messages SET hidden_by_recipient = TRUE
          WHERE sender_actor = ? AND recipient_actor = ?',
        $peer_actor, $me
    );

    $c->render(json => { ok => 1 });
}

sub delete_message ($c) {
    my $db = $c->pg->db;
    my $id = $c->param('id');
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $id =~ /^\d+$/;

    my $session_user = _require_session($c);
    return $c->render(json => { error => 'unauthenticated' }, status => 401)
        unless $session_user;

    my $base = $c->config('base_url');
    my $me   = "$base/users/$session_user";

    my $row = $db->query(
        'SELECT id, sender_actor, recipient_actor FROM messages WHERE id = ?',
        $id
    )->hash;
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $row;

    if ($row->{sender_actor} eq $me) {
        $db->query(
            'UPDATE messages SET hidden_by_sender = TRUE WHERE id = ?', $id
        );
    } elsif ($row->{recipient_actor} eq $me) {
        $db->query(
            'UPDATE messages SET hidden_by_recipient = TRUE WHERE id = ?', $id
        );
    } else {
        return $c->render(json => { error => 'forbidden' }, status => 403);
    }

    $c->render(json => { ok => 1 });
}

1;
