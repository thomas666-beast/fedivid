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

# Seed a user
$pg->db->query('INSERT INTO users (username) VALUES (?)', 'alice');

# Known user → full document
$t->get_ok('/users/alice')
  ->status_is(200)
  ->content_type_like(qr{^application/activity\+json})
  ->json_is('/type',              'Person')
  ->json_is('/preferredUsername', 'alice')
  ->json_is('/id',                'http://localhost:3000/users/alice')
  ->json_is('/inbox',             'http://localhost:3000/users/alice/inbox')
  ->json_is('/outbox',            'http://localhost:3000/users/alice/outbox')
  ->json_is('/followers',         'http://localhost:3000/users/alice/followers')
  ->json_is('/following',         'http://localhost:3000/users/alice/following')
  ->json_has('/published');

# Unknown user → 404
$t->get_ok('/users/nobody')
  ->status_is(404);

done_testing();
