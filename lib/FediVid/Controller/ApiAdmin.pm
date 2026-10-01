package FediVid::Controller::ApiAdmin;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Mojo::JSON qw(encode_json);

sub users ($c) {
    return _require_admin($c) unless _is_admin($c);

    my $db     = $c->pg->db;
    my $search = $c->param('search') // '';
    my $limit  = $c->param('limit')  // 50;
    my $offset = $c->param('offset') // 0;
    my $sort   = $c->param('sort')   // 'created_at';
    my $dir    = $c->param('dir')    // 'asc';

    $limit  = 50 unless $limit  =~ /^\d+$/ && $limit >= 1 && $limit <= 200;
    $offset = 0  unless $offset =~ /^\d+$/ && $offset >= 0;

    my %allowed_sort = (
        username  => 1,
        created_at => 1,
        videos    => 1,
        followers => 1,
        following => 1,
    );
    $sort = 'created_at' unless $allowed_sort{$sort};
    $dir  = 'asc' unless $dir =~ /^(asc|desc)$/i;
    $dir  = uc $dir;

    # Base query with computed counts
    my $base = q{
        SELECT u.username, u.created_at, u.disabled_at,
               (SELECT COUNT(*) FROM videos v WHERE v.username = u.username) AS video_count,
               (SELECT COUNT(*) FROM followers f WHERE f.local_user = u.username AND f.accepted) AS followers_count,
               (SELECT COUNT(*) FROM following f WHERE f.local_user = u.username AND f.accepted) AS following_count,
               (SELECT COUNT(*) FROM comments c
                  JOIN videos v ON v.id = c.video_id
                 WHERE v.username = u.username AND c.is_remote = FALSE) AS comment_count
          FROM users u
    };

    my @params;
    my $where = '';
    if (length $search) {
        $where = ' WHERE u.username ILIKE ?';
        push @params, "%$search%";
    }

    # Sort
    my $order_col = {
        username   => 'u.username',
        created_at => 'u.created_at',
        videos     => 'video_count',
        followers  => 'followers_count',
        following  => 'following_count',
    }->{$sort};
    my $order = " ORDER BY $order_col $dir";

    # Count
    my $total = $db->query(
        "SELECT COUNT(*) AS n FROM users u $where",
        @params
    )->hash->{n};

    # Rows
    my $rows = $db->query(
        "$base $where $order LIMIT ? OFFSET ?",
        @params, $limit, $offset
    )->hashes;

    $c->render(json => {
        totalItems  => $total + 0,
        limit       => $limit + 0,
        offset      => $offset + 0,
        has_more    => ($offset + $limit < $total) ? 1 : 0,
        next_offset => $offset + $limit,
        sort        => $sort,
        dir         => lc $dir,
        items       => [ map {
            {
                username        => $_->{username},
                created_at      => $_->{created_at},
                disabled        => $_->{disabled_at} ? 1 : 0,
                video_count     => $_->{video_count} + 0,
                followers_count => $_->{followers_count} + 0,
                following_count => $_->{following_count} + 0,
                comment_count   => $_->{comment_count} + 0,
            }
        } @$rows ],
    });
}

sub health ($c) {
    return _require_admin($c) unless _is_admin($c);

    my $db = $c->pg->db;

    my $deliveries = $db->query(
        "SELECT
            COUNT(*) FILTER (WHERE completed_at IS NULL) AS pending,
            COUNT(*) FILTER (WHERE completed_at IS NOT NULL AND last_error IS NULL) AS succeeded,
            COUNT(*) FILTER (WHERE completed_at IS NOT NULL AND last_error IS NOT NULL) AS failed,
            COUNT(*) FILTER (WHERE completed_at IS NULL AND attempts > 0) AS retrying,
            COALESCE(MAX(attempts), 0) AS max_attempts
         FROM deliveries"
    )->hash;

    my $pending_videos = $db->query(
        "SELECT COUNT(*) AS n FROM videos WHERE transcode_status = 'pending'"
    )->hash->{n};
    my $failed_videos = $db->query(
        "SELECT COUNT(*) AS n FROM videos WHERE transcode_status = 'failed'"
    )->hash->{n};

    my $remote_actors = $db->query(
        "SELECT COUNT(*) AS n FROM remote_actors"
    )->hash->{n};

    my $recent_failures = $db->query(
        "SELECT username, inbox_url, attempts, last_error, scheduled_at
           FROM deliveries
          WHERE last_error IS NOT NULL
          ORDER BY scheduled_at DESC
          LIMIT 20"
    )->hashes;

    $c->render(json => {
        deliveries => {
            pending   => $deliveries->{pending} + 0,
            succeeded => $deliveries->{succeeded} + 0,
            failed    => $deliveries->{failed} + 0,
            retrying  => $deliveries->{retrying} + 0,
            max_attempts => $deliveries->{max_attempts} + 0,
        },
        videos => {
            transcode_pending => $pending_videos + 0,
            transcode_failed  => $failed_videos + 0,
        },
        remote_actors   => $remote_actors + 0,
        recent_failures => $recent_failures,
    });
}

sub delete_user ($c) {
    return _require_admin($c) unless _is_admin($c);

    my $username = $c->param('username');
    my $db       = $c->pg->db;

    my $user = $db->query(
        'SELECT username FROM users WHERE username = ?', $username
    )->hash;
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $user;

    my $video_files = $db->query(
        'SELECT file_path FROM videos WHERE username = ?', $username
    )->arrays->map(sub { $_->[0] })->to_array;

    my $hls_dirs = $db->query(
        'SELECT hls_dir FROM videos WHERE username = ? AND hls_dir IS NOT NULL',
        $username
    )->arrays->map(sub { $_->[0] })->to_array;

    $db->query('DELETE FROM users WHERE username = ?', $username);

    # Remove files
    for my $f (@$video_files) {
        unlink $f if defined $f && -f $f;
    }
    for my $d (@$hls_dirs) {
        next unless defined $d && -d $d;
        require File::Path;
        File::Path::remove_tree($d);
    }

    $c->render(json => { ok => 1, username => $username });
}

sub _is_admin ($c) {
    my $configured = $c->config('admin_secret');
    return 0 unless defined $configured && length $configured;

    my $provided = $c->req->headers->header('X-Admin-Token') // '';
    return _constant_eq($provided, $configured);
}

sub _require_admin ($c) {
    return $c->render(json => { error => 'forbidden' }, status => 403);
}

sub _constant_eq ($a, $b) {
    return 0 unless defined $a && defined $b;
    return 0 unless length($a) == length($b);
    my $diff = 0;
    for my $i (0 .. length($a) - 1) {
        $diff |= ord(substr($a, $i, 1)) ^ ord(substr($b, $i, 1));
    }
    return $diff == 0;
}

sub tables ($c) {
    return _require_admin($c) unless _is_admin($c);

    my $db = $c->pg->db;

    my $rows = $db->query(
        "SELECT tablename
           FROM pg_tables
          WHERE schemaname = 'public'
          ORDER BY tablename"
    )->arrays;

    my @tables;
    for my $r (@$rows) {
        my $name = $r->[0];
        next if $name eq 'mojo_migrations';
        next if $name eq 'rate_limits';

        my $count = $db->query("SELECT COUNT(*) AS n FROM \"$name\"")->hash->{n};
        push @tables, {
            name  => $name,
            count => $count + 0,
        };
    }

    $c->render(json => { items => \@tables });
}

sub table ($c) {
    return _require_admin($c) unless _is_admin($c);

    my $name   = $c->param('name') // '';
    my $limit  = $c->param('limit')  // 50;
    my $offset = $c->param('offset') // 0;

    $limit  = 50  unless $limit  =~ /^\d+$/ && $limit  >= 1 && $limit  <= 200;
    $offset = 0   unless $offset =~ /^\d+$/ && $offset >= 0;

    my $db = $c->pg->db;

    # Verify the table exists
    my $exists = $db->query(
        "SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = ?",
        $name
    )->array;
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $exists;

    my $total = $db->query("SELECT COUNT(*) AS n FROM \"$name\"")->hash->{n};

    # Sort by id if the column exists, else by first column
    my $has_id = $db->query(
        "SELECT 1 FROM information_schema.columns
          WHERE table_schema = 'public' AND table_name = ? AND column_name = 'id'",
        $name
    )->array;

    my $order = $has_id ? 'id DESC' : '1';

    my $rows = $db->query(
        "SELECT * FROM \"$name\" ORDER BY $order LIMIT ? OFFSET ?",
        $limit, $offset
    )->hashes;

    $c->render(json => {
        table       => $name,
        totalItems  => $total + 0,
        limit       => $limit + 0,
        offset      => $offset + 0,
        has_more    => ($offset + $limit < $total) ? 1 : 0,
        next_offset => $offset + $limit,
        items       => $rows,
    });
}

sub workers ($c) {
    return _require_admin($c) unless _is_admin($c);

    my $db = $c->pg->db;

    my $del = $db->query(
        "SELECT
            last_seen,
            processed,
            EXTRACT(EPOCH FROM (NOW() - last_seen)) AS idle_seconds
           FROM worker_heartbeats
          WHERE name = 'delivery'"
    )->hash;

    my $tra = $db->query(
        "SELECT
            last_seen,
            processed,
            EXTRACT(EPOCH FROM (NOW() - last_seen)) AS idle_seconds
           FROM worker_heartbeats
          WHERE name = 'transcode'"
    )->hash;

    my $del_pending = $db->query(
        "SELECT COUNT(*) AS n FROM deliveries WHERE completed_at IS NULL"
    )->hash->{n};

    my $tra_pending = $db->query(
        "SELECT COUNT(*) AS n FROM videos WHERE transcode_status = 'pending'"
    )->hash->{n};

    $c->render(json => {
        delivery  => _worker_status($del, $del_pending + 0),
        transcode => _worker_status($tra, $tra_pending + 0),
        now       => _now_iso(),
    });
}

sub _worker_status ($hb, $pending) {
    if (!$hb || !$hb->{last_seen}) {
        return {
            status        => 'never',
            last_seen     => undef,
            pending_count => $pending,
            processed     => 0,
            message       => 'Worker has never reported in',
        };
    }

    my $idle = int($hb->{idle_seconds} // 999_999);

    my $status = $idle < 15  ? 'active'
               : $idle < 60  ? 'idle'
               : $idle < 600 ? 'slow'
               :               'dead';

    my $message = $status eq 'active' ? 'Reporting in'
                : $status eq 'idle'   ? "Last seen ${idle}s ago"
                : $status eq 'slow'   ? "Last seen " . int($idle / 60) . "m ago"
                :                       "Last seen " . int($idle / 60) . "m ago - worker appears stopped";

    return {
        status        => $status,
        last_seen     => $hb->{last_seen},
        pending_count => $pending,
        processed     => $hb->{processed} + 0,
        idle_seconds  => $idle,
        message       => $message,
    };
}

sub disable_user ($c) {
    return _require_admin($c) unless _is_admin($c);

    my $username = $c->param('username');
    my $db       = $c->pg->db;

    my $user = $db->query(
        'SELECT username FROM users WHERE username = ?', $username
    )->hash;
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $user;

    $db->query(
        'UPDATE users SET disabled_at = NOW() WHERE username = ?',
        $username
    );

    $c->render(json => { ok => 1, username => $username, disabled => 1 });
}

sub enable_user ($c) {
    return _require_admin($c) unless _is_admin($c);

    my $username = $c->param('username');
    my $db       = $c->pg->db;

    my $user = $db->query(
        'SELECT username FROM users WHERE username = ?', $username
    )->hash;
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $user;

    $db->query(
        'UPDATE users SET disabled_at = NULL WHERE username = ?',
        $username
    );

    $c->render(json => { ok => 1, username => $username, disabled => 0 });
} 

sub _now_iso () {
    require POSIX;
    my @t = gmtime(time);
    return POSIX::strftime('%Y-%m-%dT%H:%M:%SZ', @t);
}

1;
