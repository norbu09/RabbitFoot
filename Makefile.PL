use inc::Module::Install;
use Module::Install::AuthorTests;
name 'Net-RabbitFoot';
all_from 'lib/Net/RabbitFoot.pm';

requires 'Moose';
requires 'MooseX::AttributeHelpers';
requires 'MooseX::App::Cmd';
requires 'MooseX::ConfigFromFile';
requires 'Config::Any';
requires 'JSON::XS';
requires 'List::MoreUtils';
requires 'Net::AMQP';
requires 'AnyEvent';
requires 'Coro';
requires 'Coro::AnyEvent';
requires 'File::ShareDir';

tests 't/*.t';
author_tests 'xt';

build_requires 'Test::More';
build_requires 'Test::Exception';
install_script 'rabbit_foot';
install_share  'share/RabbitFoot';
use_test_base;
auto_install;
WriteAll;
