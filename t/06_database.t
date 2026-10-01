use Mojo::Base -strict;
use Test::More;
use Test::Mojo;
use FindBin;
use lib "$FindBin::Bin/../lib";
use FediVid;
use lib "$FindBin::Bin/lib";
use TestDB qw(setup_test_db);

local $ENV{FEDIVID_DATABASE_URL} =
    'postgresql://postgres:1234pass@127.0.0.1/fedivid_test';

my $t  = Test::Mojo->new('FediVid');
my $pg = setup_test_db($t->app);

my $tables = $pg->db->query(
    "SELECT tablename FROM pg_tables WHERE schemaname='public'"
)->arrays->map(sub { $_->[0] })->to_array;
ok grep({ $_ eq 'users' } @$tables), 'users table exists';

$pg->db->query('TRUNCATE users RESTART IDENTITY CASCADE');

my $id = $pg->db->query(
    'INSERT INTO users (username) VALUES (?) RETURNING id', 'alice'
)->hash->{id};
ok $id, 'inserted alice, id=' . ($id // 'undef');

my $row = $pg->db->query(
    'SELECT username FROM users WHERE id = ?', $id
)->hash;
is $row->{username}, 'alice', 'selected alice back';

my $ok = eval {
    $pg->db->query('INSERT INTO users (username) VALUES (?)', 'alice');
    1;
};
ok !$ok, 'duplicate username rejected';

done_testing();
