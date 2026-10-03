package FediVid::ActivityHandler;
use Mojo::Base -strict, -signatures;
use Mojo::JSON qw(decode_json);
use FediVid::Delivery;

sub handle ($ua, $db, $config, $username, $activity, $local_priv, $local_key_id, $opts = {}) {
    my $type = $activity->{type} // '';
    return _handle_follow($ua, $db, $config, $username, $activity, $local_priv, $local_key_id)
        if $type eq 'Follow';
    return _handle_undo($ua, $db, $config, $username, $activity, $local_priv, $local_key_id)
        if $type eq 'Undo';
    return _handle_like($db, $config, $username, $activity)
        if $type eq 'Like';
    return _handle_accept($db, $config, $username, $activity)
        if $type eq 'Accept';
    return _handle_create($db, $config, $username, $activity, $opts)
        if $type eq 'Create';
    return _handle_delete($db, $activity)
        if $type eq 'Delete';
    return _handle_announce($db, $activity)
        if $type eq 'Announce';
    return _handle_update($db, $activity)
        if $type eq 'Update';

    return (1, undef);
}

sub _handle_announce ($db, $activity) {
    my $actor  = $activity->{actor};
    return (1, undef) unless $actor && !ref $actor;

    my $object = $activity->{object};
    my $object_url = ref $object eq 'HASH' ? $object->{id} : $object;
    return (1, undef) unless $object_url;

    my $activity_id = $activity->{id};
    return (1, undef) unless $activity_id;

    my $rows = $db->query(
        'SELECT local_user FROM followers
          WHERE remote_actor = ? AND accepted = TRUE',
        $actor
    )->arrays;

    my %targets;
    $targets{$_->[0]} = 1 for @$rows;

    my $also = $db->query(
        'SELECT local_user FROM following WHERE remote_actor = ?',
        $actor
    )->arrays;
    $targets{$_->[0]} = 1 for @$also;

    return (1, undef) unless %targets;

    for my $local_user (keys %targets) {
        $db->query(
            'INSERT INTO announces
                 (username, actor, object_url, activity_id, is_remote)
                  VALUES (?, ?, ?, ?, TRUE)
             ON CONFLICT (activity_id) DO NOTHING',
            $local_user, $actor, $object_url, $activity_id
        );

        require FediVid::Notifications;
        FediVid::Notifications::notify(
            $db, $local_user, 'announce', $actor, undef, $object_url
        );
    }

    return (1, undef);
}

sub _undo_announce ($db, $username, $activity) {
    my $object = $activity->{object};
    my $actor  = $activity->{actor} // $object->{actor};
    return (0, 'Undo Announce has no actor') unless $actor;

    my $activity_id = $object->{id};
    return (0, 'Undo Announce has no id') unless $activity_id;

    $db->query(
        'DELETE FROM announces WHERE username = ? AND activity_id = ?',
        $username, $activity_id
    );

    return (1, undef);
}

sub _handle_create ($db, $config, $username, $activity, $opts = {}) {
    my $object = $activity->{object};
    return (1, undef) unless ref $object eq 'HASH';

    my $otype = $object->{type} // '';
    return _handle_create_video($db, $username, $activity, $opts) if $otype eq 'Video';
    return _handle_create_note($db, $config, $activity)           if $otype eq 'Note';

    return (1, undef);
}

sub _handle_create_note ($db, $config, $activity) {
    my $actor  = $activity->{actor};
    my $object = $activity->{object};

    return (0, 'Create Note has no actor') unless $actor && !ref $actor;
    return (0, 'Create Note has no object') unless ref $object eq 'HASH';

    if ($object->{inReplyTo}) {
        return _handle_create_comment($db, $config, $activity);
    }

    my $note_to = $object->{to} // $activity->{to} // [];
    $note_to = [$note_to] unless ref $note_to eq 'ARRAY';

    my $base = $config->{scheme} . '://' . $config->{domain};

    my ($local_recipient) = map {
        my ($user) = $_ =~ m{\A\Q$base\E/users/([^/]+)\z};
        $user;
    } grep {
        $_ =~ m{\A\Q$base\E/users/}
    } @$note_to;

    return (1, undef) unless $local_recipient;

    my $exists = $db->query(
        'SELECT 1 FROM users WHERE username = ?', $local_recipient
    )->array;
    return (1, undef) unless $exists;

    my $body = $object->{content} // '';
    $body =~ s/<[^>]+>//g;
    $body =~ s/\s+\z//;
    return (1, undef) unless length $body;

    my $recipient_actor = "$base/users/$local_recipient";
    my $note_id = $object->{id};
    return (1, undef) unless $note_id;

    $db->query(
        'INSERT INTO messages
             (sender_actor, recipient_actor, body, activity_id, is_remote)
              VALUES (?, ?, ?, ?, TRUE)
         ON CONFLICT (activity_id) DO NOTHING',
        $actor, $recipient_actor, $body, $note_id
    );

    require FediVid::Notifications;
    FediVid::Notifications::notify(
        $db, $local_recipient, 'message', $actor, undef, undef
    );

    return (1, undef);
}

sub _handle_create_comment ($db, $config, $activity) {
    my $actor  = $activity->{actor};
    my $object = $activity->{object};

    my $in_reply_to = $object->{inReplyTo};
    my $video_actor = ref $in_reply_to eq 'HASH' ? $in_reply_to->{id} : $in_reply_to;
    return (1, undef) unless $video_actor;

    my $video = $db->query(
        'SELECT id, username FROM videos WHERE activity_id = ?',
        $video_actor
    )->hash;
    return (1, undef) unless $video;

    my $body = $object->{content} // '';
    $body =~ s/<[^>]+>//g;
    $body =~ s/\s+\z//;
    return (1, undef) unless length $body;

    my $note_id = $object->{id};
    return (1, undef) unless $note_id;

    $db->query(
        'INSERT INTO comments
             (video_id, video_actor, author_actor, body, activity_id, is_remote)
              VALUES (?, ?, ?, ?, ?, TRUE)
         ON CONFLICT (activity_id) DO NOTHING',
        $video->{id}, $video_actor, $actor, $body, $note_id
    );

    require FediVid::Notifications;
    FediVid::Notifications::notify(
        $db, $video->{username}, 'comment', $actor, $video->{id}, $video_actor
    );

    return (1, undef);
}

sub _handle_delete ($db, $activity) {
    my $actor = $activity->{actor};
    return (0, 'Delete has no actor') unless $actor;
    return (0, 'Delete actor is not a string') if ref $actor;

    my $object = $activity->{object};
    return (0, 'Delete has no object') unless $object;

    my $object_url = ref $object eq 'HASH' ? $object->{id} : $object;
    return (0, 'Delete object has no id') unless $object_url;

    # Only handle self-deletion (actor == object). Deletion of specific
    # videos / notes / etc. is handled elsewhere or ignored.
    return (1, undef) unless $object_url eq $actor;

    # This is a remote user deleting their account. Remove every trace of
    # them from our database so we don't keep talking to a ghost.

    # 1. Followers/following relationships both ways.
    $db->query('DELETE FROM followers WHERE remote_actor = ?', $actor);
    $db->query('DELETE FROM following WHERE remote_actor = ?', $actor);

    # 2. Videos we cached from them.
    $db->query('DELETE FROM remote_videos WHERE remote_actor = ?', $actor);

    # 3. The actor document itself (so we don't keep using a dead cache entry).
    $db->query('DELETE FROM remote_actors WHERE url = ?', $actor);

    # 4. Messages. We soft-delete by hiding both sides so the other party
    #    still sees their own copy if they're a local user, but the deleted
    #    peer no longer appears in conversation lists.
    $db->query(
        'UPDATE messages
            SET hidden_by_sender = TRUE,
                hidden_by_recipient = TRUE
          WHERE sender_actor = ? OR recipient_actor = ?',
        $actor, $actor
    );

    # 5. Comments from them. Their authorship is only meaningful if the video
    #    is still around, so a hard delete is fine — the comment was made by
    #    an account that no longer exists.
    $db->query('DELETE FROM comments WHERE author_actor = ?', $actor);

    # 6. Likes they made.
    $db->query('DELETE FROM likes WHERE remote_actor = ?', $actor);

    # 7. Announces (boosts) they made.
    $db->query('DELETE FROM announces WHERE actor = ? AND is_remote = TRUE', $actor);

    # 8. Notifications referring to them.
    $db->query('DELETE FROM notifications WHERE actor = ?', $actor);

    return (1, undef);
}

sub _handle_accept ($db, $config, $username, $activity) {
    my $object = $activity->{object};
    return (1, undef) unless ref $object eq 'HASH';
    return (1, undef) unless ($object->{type} // '') eq 'Follow';

    my $actor = $activity->{actor};
    return (0, 'Accept has no actor') unless $actor;
    return (0, 'Accept actor is not a string') if ref $actor;

    my $object_id = $object->{id};
    return (1, undef) unless $object_id;

    my $base   = $config->{scheme} . '://' . $config->{domain};
    my $expect = "$base/users/$username#follows/";
    return (1, undef) unless index($object_id, $expect) == 0;

    $db->query(
        'UPDATE following SET accepted = TRUE
          WHERE local_user = ? AND remote_actor = ? AND activity_id = ?',
        $username, $actor, $object_id
    );

    return (1, undef);
}

sub _handle_follow ($ua, $db, $config, $username, $activity, $local_priv, $local_key_id) {
    my $actor = $activity->{actor};
    return (0, 'Follow has no actor') unless $actor;
    return (0, 'Follow actor is not a string') if ref $actor;

    my $object = $activity->{object};
    return (0, 'Follow has no object') unless $object;

    my $object_url = ref $object eq 'HASH' ? $object->{id} : $object;
    return (0, 'Follow object has no id') unless $object_url;

    my $base     = $config->{scheme} . '://' . $config->{domain};
    my $expected = "$base/users/$username";
    return (0, 'Follow object does not match local user')
        unless $object_url eq $expected;

    my $remote_inbox;

    # Try the cache first
    my $cached = $db->query(
        'SELECT actor FROM remote_actors WHERE url = ?',
        _strip_fragment($actor)
    )->hash;
    if ($cached) {
        my $doc = decode_json($cached->{actor});
        $remote_inbox = $doc->{inbox};
    }

    # Cache miss — fetch the actor document on demand so we can send the Accept.
    if (!$remote_inbox) {
        require FediVid::RemoteActor;
        my ($doc, $err) = FediVid::RemoteActor::fetch($ua, $db, $actor);
        if ($doc && $doc->{inbox}) {
            $remote_inbox = $doc->{inbox};
        }
    }

    $db->query(
        'INSERT INTO followers (local_user, remote_actor, remote_inbox)
              VALUES (?, ?, ?)
         ON CONFLICT (local_user, remote_actor) DO NOTHING',
        $username, $actor, $remote_inbox
    );

    require FediVid::Notifications;
    FediVid::Notifications::notify(
        $db, $username, 'follow', $actor, undef, undef
    );

    return (1, undef) unless $remote_inbox;
    return (1, undef) unless $local_priv && $local_key_id;

    my $accept = {
        '@context' => 'https://www.w3.org/ns/activitystreams',
        id         => "$base/users/$username#accepts/" . time . '-' . int(rand(10000)),
        type       => 'Accept',
        actor      => "$base/users/$username",
        object     => $activity,
    };

    require FediVid::DeliveryQueue;
    FediVid::DeliveryQueue::enqueue($db, $username, $remote_inbox, $accept);

    $db->query(
        'UPDATE followers SET accepted = TRUE
          WHERE local_user = ? AND remote_actor = ?',
        $username, $actor
    );

    return (1, undef);
}

sub _handle_undo ($ua, $db, $config, $username, $activity, $local_priv, $local_key_id) {
    my $object = $activity->{object};
    return (1, undef) unless ref $object eq 'HASH';

    my $type = $object->{type} // '';
    return _undo_follow($db, $username, $activity)   if $type eq 'Follow';
    return _undo_like($db, $username, $activity)     if $type eq 'Like';
    return _undo_announce($db, $username, $activity) if $type eq 'Announce';

    return (1, undef);
}

sub _undo_follow ($db, $username, $activity) {
    my $object = $activity->{object};
    my $actor  = $activity->{actor} // $object->{actor};
    return (0, 'Undo Follow has no actor') unless $actor;

    $db->query(
        'DELETE FROM followers WHERE local_user = ? AND remote_actor = ?',
        $username, $actor
    );

    return (1, undef);
}

sub _undo_like ($db, $username, $activity) {
    my $object = $activity->{object};
    my $actor  = $activity->{actor} // $object->{actor};
    return (0, 'Undo Like has no actor') unless $actor;

    my $target = ref $object->{object} eq 'HASH'
        ? $object->{object}{id}
        : $object->{object};
    $target //= $object->{id};

    return (0, 'Undo Like object has no target') unless $target;

    my $video = _find_video($db, $username, $target);
    return (1, undef) unless $video;

    $db->query(
        'DELETE FROM likes WHERE video_id = ? AND remote_actor = ?',
        $video->{id}, $actor
    );

    return (1, undef);
}

sub _handle_like ($db, $config, $username, $activity) {
    my $actor = $activity->{actor};
    return (0, 'Like has no actor') unless $actor;
    return (0, 'Like actor is not a string') if ref $actor;

    my $object = $activity->{object};
    return (0, 'Like has no object') unless $object;

    my $object_url = ref $object eq 'HASH' ? $object->{id} : $object;
    return (0, 'Like object has no id') unless $object_url;

    my $video = _find_video($db, $username, $object_url);
    return (1, undef) unless $video;

    $db->query(
        'INSERT INTO likes (video_id, remote_actor, activity_id)
              VALUES (?, ?, ?)
         ON CONFLICT (video_id, remote_actor) DO NOTHING',
        $video->{id}, $actor, $activity->{id} // _fallback_activity_id($activity)
    );

    require FediVid::Notifications;
    FediVid::Notifications::notify(
        $db, $username, 'like', $actor, $video->{id}, $object_url
    );

    return (1, undef);
}

sub _handle_update ($db, $activity) {
    my $actor  = $activity->{actor};
    my $object = $activity->{object};

    return (1, undef) unless $actor && !ref $actor;
    return (1, undef) unless ref $object eq 'HASH';
    return (1, undef) unless ($object->{type} // '') eq 'Video';

    my $object_id = $object->{id};
    return (1, undef) unless $object_id;

    my $title       = $object->{name}    // '';
    my $description = $object->{summary} // '';

    $db->query(
        'UPDATE remote_videos
            SET title = ?, description = ?
          WHERE object_id = ? AND remote_actor = ?',
        $title, $description, $object_id, $actor
    );

    return (1, undef);
}

sub _find_video ($db, $username, $object_url) {
    my $video = $db->query(
        'SELECT id, activity_id FROM videos
          WHERE username = ? AND activity_id = ?',
        $username, $object_url
    )->hash;
    return $video if $video;

    my ($path) = $object_url =~ m{/videos/([^/?]+)};
    return undef unless $path;

    return $db->query(
        'SELECT id, activity_id FROM videos
          WHERE username = ? AND activity_id LIKE ?',
        $username, "%/$path"
    )->hash;
}

sub _fallback_activity_id ($activity) {
    my $actor  = $activity->{actor}  // '';
    my $object = ref $activity->{object} eq 'HASH'
        ? $activity->{object}{id}
        : $activity->{object};
    # Deterministic: same input always produces the same fallback ID.
    # Some peers omit 'id' on Like activities; using a hash of the content
    # (rather than time()) makes retries and duplicates collapse onto the
    # same activity_id, so ON CONFLICT works as intended.
    require Digest::SHA;
    my $h = Digest::SHA::sha256_hex("like\x00$actor\x00$object");
    return "urn:fedivid:like:$h";
}
sub _strip_fragment ($url) {
    (my $u = $url) =~ s/#.*\z//;
    return $u;
}

sub _handle_create_video ($db, $username, $activity, $opts = {}) {
    my $actor  = $activity->{actor};
    my $object = $activity->{object};

    return (1, undef) unless $actor && !ref $actor;
    return (1, undef) unless ref $object eq 'HASH';
    return (1, undef) unless ($object->{type} // '') eq 'Video';

    my $object_id = $object->{id};
    return (1, undef) unless $object_id;

    my $rows = $db->query(
        'SELECT local_user FROM followers
          WHERE remote_actor = ? AND accepted = TRUE',
        $actor
    )->arrays;

    my $also = $db->query(
        'SELECT local_user FROM following WHERE remote_actor = ?',
        $actor
    )->arrays;

    my %targets;
    $targets{$_->[0]} = 1 for @$rows, @$also;

    return (1, undef) unless %targets;

    my $title       = $object->{name}         // '';
    my $description = $object->{summary}      // '';
    my $url         = ref $object->{url} eq 'HASH'
        ? $object->{url}{href}
        : $object->{url};
    $url //= $object_id;
    my $media_type  = $object->{mediaType}    // 'video/mp4';
    my $duration    = $object->{duration}     ? 0 + $object->{duration} : undef;
    my $width       = $object->{width}        ? 0 + $object->{width}    : undef;
    my $height      = $object->{height}       ? 0 + $object->{height}   : undef;
    my $published   = $object->{published} // $activity->{published};

    my $poster_url;
    if (ref $object->{icon} eq 'HASH') {
        $poster_url = $object->{icon}{url};
    } elsif (!ref $object->{icon} && defined $object->{icon}) {
        $poster_url = $object->{icon};
    }

    my @tags;

    if (ref $object->{tag} eq 'ARRAY') {
        for my $t (@{ $object->{tag} }) {
            next unless ref $t eq 'HASH';
            next unless ($t->{type} // '') eq 'Hashtag';
            my $name = $t->{name} // '';
            $name =~ s/^#//;
            $name = lc $name;
            $name =~ s/[^a-z0-9_\-]//g;
            push @tags, $name if length $name >= 2 && length $name <= 30;
        }
    }

    for my $local_user (keys %targets) {
        $db->query(
            'INSERT INTO remote_videos
                 (local_user, remote_actor, object_id, title, description,
                  video_url, media_type, duration, width, height, published_at, poster_url, tags)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
             ON CONFLICT (local_user, object_id) DO NOTHING',
            $local_user, $actor, $object_id,
            $title, $description, $url, $media_type,
            $duration, $width, $height, $published,
            $poster_url,
            '{' . join(',', @tags) . '}',
        );

        my $rv = $db->query(
            'SELECT id FROM remote_videos WHERE local_user = ? AND object_id = ?',
            $local_user, $object_id
        )->hash;

        unless ($opts->{skip_notifications}) {
            require FediVid::Notifications;
            FediVid::Notifications::notify(
                $db, $local_user, 'create', $actor, $object_id, $url,
                $rv ? $rv->{id} : undef
            );
        }
    }

    return (1, undef);
}

1;
