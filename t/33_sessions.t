use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use TestDB qw(setup_test_db);
use FediVid;
use FediVid::Signature qw(sign_request);
use FediVid::Password qw(hash_password check_password);
use Mojo::JSON qw(encode_json);
use Mojo::Util qw(b64_encode);
use Crypt::OpenSSL::RSA;

local $ENV{FEDIVID_DATABASE_URL} =
    'postgresql://postgres:1234pass@127.0.0.1/fedivid_test';
local $ENV{FEDIVID_RATE_LIMIT_DISABLED} = 1;

my $t  = Test::Mojo->new('FediVid');
my $pg = setup_test_db($t->app);

local $ENV{FEDIVID_ADMIN_SECRET} = 'test-admin-token';

$t->post_ok('/api/users',
    { 'X-Admin-Token' => 'test-admin-token' },
    json => { username => 'alice' }, )
  ->status_is(201);

# --- Password hashing primitives ---
{
    my $hash = hash_password('correct horse battery staple');
    ok $hash, 'hash produced';
    like $hash, qr/^\$2a\$/, 'looks like bcrypt ($2a$)';
    ok check_password('correct horse battery staple', $hash), 'correct password verifies';
    ok !check_password('wrong', $hash), 'wrong password rejected';
    ok !check_password('correct horse battery staple', undef), 'undef hash rejects';
}

# --- Set password via signed request ---
my $alice = $pg->db->query(
    'SELECT private_key_pem FROM users WHERE username = ?', 'alice'
)->hash;

my $key_id = 'http://localhost:3000/users/alice#main-key';

{
    my $body = encode_json({ new_password => 'hunter2hunter2' });
    my $tx = $t->ua->build_tx(POST => '/api/users/alice/password');
    $tx->req->headers->content_type('application/activity+json');
    $tx->req->body($body);
    sign_request($tx->req, $key_id, $alice->{private_key_pem});
    $t->ua->start($tx);
    is $tx->res->code, 200, 'password set';
    is $tx->res->json->{ok}, 1, 'ok response';
}

# --- Login with wrong password ---
$t->post_ok('/api/sessions', json => {
    username => 'alice', password => 'wrong'
})->status_is(401)->json_is('/error', 'invalid_credentials');

# --- Login with unknown user ---
$t->post_ok('/api/sessions', json => {
    username => 'nobody', password => 'whatever'
})->status_is(401);

# --- Login with correct password ---
$t->post_ok('/api/sessions', json => {
    username => 'alice', password => 'hunter2hunter2'
})->status_is(200)->json_is('/username', 'alice');

my $cookie = $t->tx->res->cookie('fedivid_session');
ok $cookie, 'session cookie set';

diag "COOKIE VALUE: " . $cookie->value;
diag "JAR: " . join(",", map { $_->name . "=" . ($_->value // "undef") } @{ $t->ua->cookie_jar->all });

# --- me endpoint with cookie ---
$t->get_ok('/api/sessions/me')
  ->status_is(200)
  ->json_is('/username', 'alice');

# --- Tampered cookie rejected ---
{
    my $bad = b64_encode('alice:9999999999.badsig', '');
    $t->ua->cookie_jar->empty;
    $t->get_ok('/api/sessions/me', { Cookie => "fedivid_session=$bad" })
      ->status_is(401);
}

# --- Restore good session cookie ---
$t->ua->cookie_jar->empty;
$t->post_ok('/api/sessions', json => {
    username => 'alice', password => 'hunter2hunter2'
})->status_is(200);

# --- Session cookie can drive upload (no signature needed) ---
my $sample = '/tmp/fedivid-session-test.mp4';
system('ffmpeg', '-y', '-loglevel', 'error',
    '-f', 'lavfi', '-i', 'testsrc=duration=1:size=160x120:rate=10',
    '-pix_fmt', 'yuv420p',
    $sample,
) == 0 or die "ffmpeg failed";
my $bytes = do {
    open my $fh, '<:raw', $sample or die $!;
    local $/; <$fh>;
};

{
    $t->post_ok('/users/alice/videos', json => {
        title        => 'Session upload',
        content_type => 'video/mp4',
        data         => b64_encode($bytes, ''),
    })->status_is(201);
}

# --- Logout clears cookie ---
$t->delete_ok('/api/sessions')->status_is(200);

$t->get_ok('/api/sessions/me')->status_is(401);

done_testing();
