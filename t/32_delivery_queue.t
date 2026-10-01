use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";
use TestDB qw(setup_test_db);
use FediVid;
use FediVid::DeliveryQueue qw(enqueue);
use Crypt::OpenSSL::RSA;
use Mojo::JSON qw(encode_json decode_json);

local $ENV{FEDIVID_DATABASE_URL} =
    'postgresql://postgres:1234pass@127.0.0.1/fedivid_test';

my $t  = Test::Mojo->new('FediVid');
my $pg = setup_test_db($t->app);

local $ENV{FEDIVID_ADMIN_SECRET} = 'test-admin-token';

$t->post_ok('/api/users',
    { 'X-Admin-Token' => 'test-admin-token' },
    json => { username => 'alice' },
)->status_is(201);

# --- Enqueue ---
{
    my $activity = {
        id   => 'http://localhost:3000/activities/1',
        type => 'Create',
        actor => 'http://localhost:3000/users/alice',
    };
    my ($ok, $err) = enqueue(
        $pg->db, 'alice', 'https://remote.test/users/bob/inbox', $activity
    );
    ok $ok, 'enqueue succeeds' or diag "error: $err";

    my $row = $pg->db->query(
        'SELECT * FROM deliveries WHERE username = ?', 'alice'
    )->hash;
    ok $row, 'row exists';
    is $row->{inbox_url},   'https://remote.test/users/bob/inbox', 'inbox stored';
    is $row->{activity_id}, 'http://localhost:3000/activities/1',   'activity_id stored';
    is $row->{attempts} + 0, 0, 'attempts is 0';
    ok !$row->{completed_at}, 'not completed';
    ok !$row->{last_error},   'no error yet';
}

# --- Enqueue with no inbox ---
{
    my ($ok, $err) = enqueue($pg->db, 'alice', '', { id => 'x', type => 'Create' });
    ok !$ok, 'empty inbox rejected';
    like $err, qr/no inbox/, 'error mentions inbox';
}

# --- Enqueue with no activity id ---
{
    my ($ok, $err) = enqueue($pg->db, 'alice', 'https://x/inbox', { type => 'Create' });
    ok !$ok, 'activity without id rejected';
    like $err, qr/no id/i, 'error mentions id';
}

done_testing();
