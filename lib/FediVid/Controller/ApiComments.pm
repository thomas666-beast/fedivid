package FediVid::Controller::ApiComments;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Mojo::JSON qw(encode_json);
use Mojo::Util qw(trim);
use FediVid::Signature qw(verify_request verify_digest);

sub index ($c) {
    my $owner_username = $c->param('username');
    my $video_id       = $c->param('id');
    my $db             = $c->pg->db;

    my $video = $db->query(
        'SELECT id, activity_id FROM videos WHERE id = ? AND username = ?',
        $video_id, $owner_username
    )->hash;
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $video;

    my $base = $c->config('base_url');

    my $rows = $db->query(
        'SELECT id, author_actor, body, is_remote, created_at
           FROM comments
          WHERE video_actor = ?
          ORDER BY created_at ASC
          LIMIT 500',
        $video->{activity_id}
    )->hashes;

    $c->render(json => {
        totalItems => scalar @$rows,
        items      => [ map { _render_comment($_, $base) } @$rows ],
    });
}

sub create ($c) {
    my $owner_username = $c->param('username');
    my $video_id       = $c->param('id');
    my $db             = $c->pg->db;

    # Who is commenting? From the session.
    my $session_user = eval {
        require FediVid::Controller::Sessions;
        FediVid::Controller::Sessions::_current_user($c);
    };
    return $c->render(json => { error => 'unauthorized' }, status => 401)
        unless $session_user;

    # Confirm the commenter exists
    my $user = $db->query(
        'SELECT private_key_pem FROM users WHERE username = ?', $session_user
    )->hash;
    return $c->render(json => { error => 'unauthorized' }, status => 401)
        unless $user;

    # Confirm the video exists and belongs to :username
    my $video = $db->query(
        'SELECT id, activity_id FROM videos WHERE id = ? AND username = ?',
        $video_id, $owner_username
    )->hash;
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $video;

    my $body = $c->req->json // {};
    my $text = trim($body->{body} // '');
    return $c->render(json => { error => 'empty_body' }, status => 400)
        unless length $text;
    return $c->render(json => { error => 'too_long' }, status => 400)
        if length($text) > 2000;

    my $base = $c->config('base_url');
    my $author_actor = "$base/users/$session_user";

    my $activity_id = "$base/users/$session_user#comments/" . time . '-' . int(rand(1_000_000));
    my $note_id     = "$activity_id#object";

    my $row = $db->query(
        'INSERT INTO comments
             (video_id, video_actor, author_actor, body, activity_id, is_remote)
              VALUES (?, ?, ?, ?, ?, FALSE)
         RETURNING id, created_at',
        $video->{id}, $video->{activity_id}, $author_actor,
        $text, $note_id
    )->hash;

    $row->{author_actor} = $author_actor;
    $row->{body}         = $text;
    $row->{is_remote}    = 0;

    # Deliver to remote video owner if applicable
    my $deliver_to;
    my $video_actor = $video->{activity_id};
    if ($video_actor !~ m{\A\Q$base\E/users/}) {
        my ($remote_actor) = $video_actor =~ m{\A(https?://[^/]+/users/[^/]+)};
        if ($remote_actor) {
            my ($actor_doc) = eval {
                require FediVid::RemoteActor;
                FediVid::RemoteActor::fetch($c->ua, $db, $remote_actor)
            };
            $deliver_to = $actor_doc->{inbox} if $actor_doc;
        }
    }

    if ($deliver_to) {
        my $activity = {
            '@context' => 'https://www.w3.org/ns/activitystreams',
            id         => $activity_id,
            type       => 'Create',
            actor      => $author_actor,
            to         => [$deliver_to],
            object     => {
                id           => $note_id,
                type         => 'Note',
                attributedTo => $author_actor,
                inReplyTo    => $video_actor,
                content      => $text,
                mediaType    => 'text/plain',
                published    => _now_iso(),
            },
        };

        require FediVid::DeliveryQueue;
        FediVid::DeliveryQueue::enqueue($db, $session_user, $deliver_to, $activity);
    }

    $c->res->headers->content_type('application/json');
    $c->render(
        status => 201,
        data   => encode_json(_render_comment($row, $base)),
    );
}

sub delete ($c) {
    my $owner_username = $c->param('username');
    my $video_id       = $c->param('id');
    my $comment_id     = $c->param('comment_id');
    my $db             = $c->pg->db;

    my $session_user = eval {
        require FediVid::Controller::Sessions;
        FediVid::Controller::Sessions::_current_user($c);
    };
    return $c->render(json => { error => 'unauthorized' }, status => 401)
        unless $session_user;

    my $video = $db->query(
        'SELECT id FROM videos WHERE id = ? AND username = ?',
        $video_id, $owner_username
    )->hash;
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $video;

    my $base = $c->config('base_url');
    my $author_actor = "$base/users/$session_user";

    my $row = $db->query(
        'SELECT id, author_actor, is_remote FROM comments
          WHERE id = ? AND video_id = ?',
        $comment_id, $video->{id}
    )->hash;
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $row;

    return $c->render(json => { error => 'forbidden' }, status => 403)
        unless !$row->{is_remote} && $row->{author_actor} eq $author_actor;

    $db->query('DELETE FROM comments WHERE id = ?', $row->{id});

    $c->render(json => { ok => 1 });
}

sub _render_comment ($row, $base) {
    my $author = $row->{author_actor};
    my $display_author;
    if ($author =~ m{\A\Q$base\E/users/([^/]+)\z}) {
        $display_author = $1;
    } else {
        (my $short = $author) =~ s{\Ahttps?://}{};
        $display_author = '@' . $short;
    }
    return {
        id         => $row->{id} + 0,
        username   => $display_author,
        body       => $row->{body},
        is_remote  => $row->{is_remote} ? 1 : 0,
        created_at => $row->{created_at},
    };
}

sub create_remote ($c) {
    my $video_id = $c->param('id');

    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $video_id =~ /^\d+$/;

    my $db       = $c->pg->db;

    my $session_user = eval {
        require FediVid::Controller::Sessions;
        FediVid::Controller::Sessions::_current_user($c);
    };
    return $c->render(json => { error => 'unauthorized' }, status => 401)
        unless $session_user;

    my $user = $db->query(
        'SELECT private_key_pem FROM users WHERE username = ?', $session_user
    )->hash;
    return $c->render(json => { error => 'unauthorized' }, status => 401)
        unless $user;

    my $video = $db->query(
        'SELECT id, remote_actor, object_id FROM remote_videos WHERE id = ?',
        $video_id
    )->hash;
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $video;

    my $body = $c->req->json // {};
    my $text = trim($body->{body} // '');
    return $c->render(json => { error => 'empty_body' }, status => 400)
        unless length $text;
    return $c->render(json => { error => 'too_long' }, status => 400)
        if length($text) > 2000;

    my $base = $c->config('base_url');
    my $author_actor = "$base/users/$session_user";
    my $activity_id = "$base/users/$session_user#comments/" . time . '-' . int(rand(1_000_000));
    my $note_id     = "$activity_id#object";

    # Insert into comments with video_id = NULL, video_actor = the remote object id
    my $row = $db->query(
        'INSERT INTO comments
             (video_id, video_actor, author_actor, body, activity_id, is_remote)
              VALUES (NULL, ?, ?, ?, ?, FALSE)
         RETURNING id, created_at',
        $video->{object_id}, $author_actor, $text, $note_id
    )->hash;

    $row->{author_actor} = $author_actor;
    $row->{body}         = $text;
    $row->{is_remote}    = 0;

    # Deliver to the remote video's owner
    my ($remote_actor) = $video->{object_id} =~ m{\A(https?://[^/]+/users/[^/]+)};
    if ($remote_actor) {
        my ($actor_doc) = eval {
            require FediVid::RemoteActor;
            FediVid::RemoteActor::fetch($c->ua, $db, $remote_actor)
        };
        if ($actor_doc && $actor_doc->{inbox}) {
            my $activity = {
                '@context' => 'https://www.w3.org/ns/activitystreams',
                id         => $activity_id,
                type       => 'Create',
                actor      => $author_actor,
                to         => [$actor_doc->{inbox}],
                object     => {
                    id           => $note_id,
                    type         => 'Note',
                    attributedTo => $author_actor,
                    inReplyTo    => $video->{object_id},
                    content      => $text,
                    mediaType    => 'text/plain',
                    published    => _now_iso(),
                },
            };

            require FediVid::DeliveryQueue;
            FediVid::DeliveryQueue::enqueue(
                $db, $session_user, $actor_doc->{inbox}, $activity
            );
        }
    }

    $c->res->headers->content_type('application/json');
    $c->render(
        status => 201,
        data   => encode_json(_render_comment($row, $base)),
    );
}

sub list_remote ($c) {
    my $video_id = $c->param('id');

    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $video_id =~ /^\d+$/;

    my $db       = $c->pg->db;

    my $video = $db->query(
        'SELECT object_id FROM remote_videos WHERE id = ?',
        $video_id
    )->hash;
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $video;

    my $base = $c->config('base_url');

    my $rows = $db->query(
        'SELECT id, author_actor, body, is_remote, created_at
           FROM comments
          WHERE video_actor = ?
          ORDER BY created_at ASC
          LIMIT 500',
        $video->{object_id}
    )->hashes;

    $c->render(json => {
        totalItems => scalar @$rows,
        items      => [ map { _render_comment($_, $base) } @$rows ],
    });
}

sub _now_iso () {
    require POSIX;
    my @t = gmtime(time);
    return POSIX::strftime('%Y-%m-%dT%H:%M:%SZ', @t);
}

1;
