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

$pg->db->query('INSERT INTO users (username) VALUES (?)', 'alice');

# Known user
$t->get_ok('/.well-known/webfinger?resource=acct:alice@localhost:3000')
  ->status_is(200)
  ->content_type_like(qr{^application/jrd\+json})
  ->json_is('/subject',      'acct:alice@localhost:3000')
  ->json_is('/links/0/rel',  'self')
  ->json_is('/links/0/type', 'application/activity+json')
  ->json_is('/links/0/href', 'http://localhost:3000/users/alice');

# Valid format, user does not exist
$t->get_ok('/.well-known/webfinger?resource=acct:bob@localhost:3000')
  ->status_is(404);

# Wrong domain
$t->get_ok('/.well-known/webfinger?resource=acct:alice@elsewhere.test')
  ->status_is(404);

# Missing param
$t->get_ok('/.well-known/webfinger')
  ->status_is(404);

done_testing();
