package FediVid;
use Mojo::Base 'Mojolicious', -signatures;
use Mojo::Pg;

sub startup ($self) {
    # ---- Config ----
    $self->plugin('JSONConfig' => {
        file => $self->home->rel_file('config/fedivid.json'),
    });

    $self->config(show_exceptions => 1);

    my $c = $self->config;
    $c->{allow_signup}   = $ENV{FEDIVID_ALLOW_SIGNUP}   if defined $ENV{FEDIVID_ALLOW_SIGNUP};
    $c->{scheme}         = $ENV{FEDIVID_SCHEME}         if $ENV{FEDIVID_SCHEME};
    $c->{domain}         = $ENV{FEDIVID_DOMAIN}         if $ENV{FEDIVID_DOMAIN};
    $c->{base_url}       = $ENV{FEDIVID_BASE_URL}       if $ENV{FEDIVID_BASE_URL};
    $c->{redis_url}      = $ENV{FEDIVID_REDIS_URL}      if $ENV{FEDIVID_REDIS_URL};
    $c->{database_url}   = $ENV{FEDIVID_DATABASE_URL}   if $ENV{FEDIVID_DATABASE_URL};
    $c->{upload_dir}     = $ENV{FEDIVID_UPLOAD_DIR}     if $ENV{FEDIVID_UPLOAD_DIR};
    $c->{session_secret} = $ENV{FEDIVID_SESSION_SECRET} if $ENV{FEDIVID_SESSION_SECRET};
    $c->{admin_secret}   = $ENV{FEDIVID_ADMIN_SECRET}   if $ENV{FEDIVID_ADMIN_SECRET};

    $c->{instance_name}        = $ENV{FEDIVID_INSTANCE_NAME}        if $ENV{FEDIVID_INSTANCE_NAME};
    $c->{instance_description} = $ENV{FEDIVID_INSTANCE_DESCRIPTION} if $ENV{FEDIVID_INSTANCE_DESCRIPTION};
    $c->{listen}               = $ENV{FEDIVID_LISTEN}               if $ENV{FEDIVID_LISTEN};

    $c->{instance_contact} = $ENV{FEDIVID_INSTANCE_CONTACT} if $ENV{FEDIVID_INSTANCE_CONTACT};
    $c->{instance_banner}  = $ENV{FEDIVID_INSTANCE_BANNER}  if $ENV{FEDIVID_INSTANCE_BANNER};
    $c->{instance_rules}   = $ENV{FEDIVID_INSTANCE_RULES}   if $ENV{FEDIVID_INSTANCE_RULES};

    $self->config(hypnotoad => {
        listen  => [$c->{listen} // 'http://127.0.0.1:3000'],
        workers => 4,
        pid_file => '/srv/fedivid/hypnotoad.pid',
        heartbeat_timeout => 30,
    });

    # Derive base_url if not set explicitly
    $c->{base_url} //= $c->{scheme} . '://' . $c->{domain};

    # ---- Upload size limit ----
    $self->max_request_size(500 * 1024 * 1024);   # 500 MiB

    # ---- Database ----
    my $pg = Mojo::Pg->new($c->{database_url});
    $self->helper(pg => sub { $pg });

    if ($self->mode eq 'development') {
        $pg->migrations
           ->from_file($self->home->rel_file('migrations.sql'))
           ->migrate;
    }

    # ---- Static frontend ----
    push @{ $self->static->paths }, $self->home->rel_file('frontend/dist');

    # ---- Routes ----
    my $r = $self->routes;

    $r->websocket('/api/ws/messages')->to(cb => sub ($c) {
        my $username = eval {
            require FediVid::Controller::Sessions;
            FediVid::Controller::Sessions::_current_user($c);
        };
        unless ($username) {
            $c->send({json => { type => 'error', error => 'unauthorized' }});
            $c->finish;
            return;
        }

        my $base = $c->config('base_url');
        my $me   = "$base/users/$username";
        my $db   = $c->pg->db;

        my $last_id = $db->query(
            'SELECT COALESCE(MAX(id), 0) AS n FROM messages WHERE recipient_actor = ?',
            $me
        )->hash->{n};

        $c->send({json => { type => 'hello', username => $username }});

        my $timer = Mojo::IOLoop->recurring(2 => sub {
            my $rows = $db->query(
                'SELECT id, sender_actor, body, created_at
                   FROM messages
                  WHERE recipient_actor = ? AND id > ?
                  ORDER BY id ASC
                  LIMIT 50',
                $me, $last_id
            )->hashes;

            for my $m (@$rows) {
                $last_id = $m->{id} if $m->{id} > $last_id;

                my $sender = $m->{sender_actor};
                if ($sender =~ m{\A\Q$base\E/users/([^/]+)\z}) {
                    $sender = $1;
                } else {
                    (my $s = $sender) =~ s{\Ahttps?://}{};
                    $sender = '@' . $s;
                }

                $c->send({json => {
                    type       => 'message',
                    id         => $m->{id} + 0,
                    sender     => $sender,
                    body       => $m->{body},
                    created_at => $m->{created_at},
                }});
            }
        });

        $c->on(finish => sub {
            Mojo::IOLoop->remove($timer) if defined $timer;
        });
    });

    _routes_health($r);
    _routes_federation($r);
    _routes_sessions($r);
    _routes_users($r);
    _routes_videos($r);
    _routes_comments($r);
    _routes_following($r);
    _routes_announces($r);
    _routes_messages($r);
    _routes_notifications($r);
    _routes_search($r);
    _routes_admin($r);
    _routes_feeds($r);
    _routes_spa($r);
}

# ---- Route groups ----

sub _routes_health ($r) {
    $r->get('/health')->to(cb => sub ($c) {
        $c->render(json => {
            status  => 'ok',
            service => $c->config('service_name'),
            mode    => $c->app->mode,
            domain  => $c->config('domain'),
        });
    });

    $r->get('/api/instance')->to('api_instance#show');
    $r->get('/api/instance/about')->to('api_instance#about');
    $r->get('/actor')->to('api_instance#actor');
}

sub _routes_federation ($r) {
    # ActivityPub surface — served as JSON, no SPA fallback
    $r->get('/.well-known/webfinger')->to('web_finger#show');

    $r->get('/users/:username')->to('actor#show');
    $r->get('/users/:username/outbox')->to('actor#outbox');
    $r->post('/users/:username/inbox')->to('actor#inbox');
}

sub _routes_sessions ($r) {
    $r->post('/api/sessions')->to('sessions#create');
    $r->delete('/api/sessions')->to('sessions#destroy');
    $r->get('/api/sessions/me')->to('sessions#me');
}

sub _routes_users ($r) {
    $r->post('/api/users')->to('users#create');
    $r->post('/api/users/:username/password')->to('passwords#update');
    $r->get('/api/users/:username/profile')->to('api_profile#show');
    $r->get('/api/users/:username/followers')->to('api_profile#followers');
    $r->delete('/api/users/:username')->to('api_settings#delete_account');

    $r->get('/api/remote-actors/*handle')->to('api_remote_actors#show');

    $r->post('/api/users/:username/avatar')->to('api_avatar#upload');
    $r->delete('/api/users/:username/avatar')->to('api_avatar#delete');
    $r->get('/users/:username/avatar')->to('api_avatar#show');
}

sub _routes_videos ($r) {
    # Public listing
    $r->get('/api/users/:username/videos')->to('api_videos#index');

    # Single video + actions
    $r->get('/api/users/:username/videos/:id')->to('api_videos#show');
    $r->post('/api/users/:username/videos/:id/like')->to('api_videos#like');
    $r->delete('/api/users/:username/videos/:id/like')->to('api_videos#like');
    $r->get('/api/users/:username/videos/:id/like')->to('api_videos#like_status');
    $r->patch('/api/users/:username/videos/:id')->to('api_video_edit#update');

    # Timeline (auth required)
    $r->get('/api/users/:username/timeline')->to('api_timeline#index');

    # Upload + serve (specific HLS route before the catch-all file route)
    $r->post('/users/:username/videos')->to('videos#create');
    $r->get('/users/:username/videos/:id/hls/*file')->to('videos#hls');
    $r->get('/users/:username/videos/*filename')->to('videos#show');

    $r->get('/api/timeline/local')->to('api_timeline#local');
    $r->get('/api/timeline/federated')->to('api_timeline#federated');

    $r->delete('/api/users/:username/videos/:id')->to('api_video_edit#delete');

    $r->get('/api/remote-videos/:id')->to('api_remote_videos#show');

    $r->get('/remote-posters/:id.jpg')->to('api_remote_videos#poster');
}

sub _routes_comments ($r) {
    $r->get('/api/users/:username/videos/:id/comments')->to('api_comments#index');
    $r->post('/api/users/:username/videos/:id/comments')->to('api_comments#create');
    $r->delete('/api/users/:username/videos/:id/comments/:comment_id')->to('api_comments#delete');

    $r->get('/api/remote-videos/:id/comments')->to('api_comments#list_remote');
    $r->post('/api/remote-videos/:id/comments')->to('api_comments#create_remote');
}

sub _routes_following ($r) {
    $r->get('/api/users/:username/following')->to('following#index');
    $r->post('/api/users/:username/following')->to('following#create');
    $r->delete('/api/users/:username/following')->to('following#remove');
}

sub _routes_announces ($r) {
    $r->get('/api/users/:username/announces')->to('api_announces#index');
    $r->post('/api/users/:username/announces')->to('api_announces#create');
    $r->delete('/api/users/:username/announces/:id')->to('api_announces#delete');
}

sub _routes_messages ($r) {
    $r->post('/api/messages')->to('api_messages#send');
    $r->get('/api/messages/inbox')->to('api_messages#inbox');
    $r->get('/api/messages/thread/:username')->to('api_messages#thread');
    $r->post('/api/messages/thread/:username/read')->to('api_messages#thread_read');
    $r->get('/api/messages/conversations')->to('api_messages#conversations');

    $r->delete('/api/messages/thread/:username')->to('api_messages#delete_thread');
    $r->delete('/api/messages/:id')->to('api_messages#delete_message');
}

sub _routes_notifications ($r) {
    $r->get('/api/users/:username/notifications')->to('api_notifications#index');
    $r->post('/api/users/:username/notifications/seen')->to('api_notifications#seen');
}

sub _routes_search ($r) {
    $r->get('/api/search')->to('api_search#index');
}

sub _routes_admin ($r) {
    $r->get('/api/admin/users')->to('api_admin#users');
    $r->get('/api/admin/health')->to('api_admin#health');
    $r->delete('/api/admin/users/:username')->to('api_admin#delete_user');

    $r->get('/api/admin/tables')->to('api_admin#tables');
    $r->get('/api/admin/table/:name')->to('api_admin#table');
    $r->get('/api/admin/workers')->to('api_admin#workers');

    $r->post('/api/admin/users/:username/disable')->to('api_admin#disable_user');
    $r->post('/api/admin/users/:username/enable')->to('api_admin#enable_user');
}

sub _routes_feeds ($r) {
    $r->get('/feed.xml')->to('feed#instance');
    $r->get('/users/:username/feed.xml')->to('feed#user');
}

sub _routes_spa ($r) {
    $r->any('/*whatever' => { whatever => '' } => sub ($c) {
        my $path = $c->param('whatever') // '';

        if (length $path && $path !~ /\.\./) {
            my $file = $c->app->home->rel_file("frontend/dist/$path");
            if (-f $file->to_string) {
                return $c->reply->static($path);
            }
        }

        # Never cache index.html — Vite changes the asset hash on every build
        $c->res->headers->header('Cache-Control' => 'no-cache, no-store, must-revalidate');
        $c->res->headers->header('Pragma' => 'no-cache');
        $c->res->headers->header('Expires' => '0');

        $c->reply->static('index.html');
    });
}

1;
