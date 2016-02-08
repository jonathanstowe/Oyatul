use v6;

=begin pod

=head1 NAME 

Oyatul - Abstract representation of filesystem layout

=head1 SYNOPSIS

=begin code

=end code

=head1 DESCRIPTION

=end pod

use JSON::Tiny;

module Oyatul:ver<0.0.1> {

    role Node { ... }
    class File { ... }
    class Directory { ... }

    role Template[$real-type] {
        method create() {
            True;
        }

        method make-real(Str $name) {
            my %h = self.to-hash();
            %h<name> = $name;
            my $real = $real-type.from-hash(parent => self.parent, %h);
            self.parent.children.append: $real;
            $real;
        }
        method is-template() {
            True;
        }
        
    }

    my role Parent {
        has Node @.children;
        method gather-children(IO::Path:D $root) {
            for $root.dir(test => /^<-[.]>/) -> $child {
                my $node;
                if $child.d {
                    $node = Directory.generate(root => $child, parent => self);
                }
                else {
                    $node = File.new(name => $child.basename, parent => self);
                }
                self.children.append: $node;
            }
        }

        method to-hash(Parent:D:) {
            my %h = type => self.what, children => [];
            %h<name> = self.name if self.can('name');
            for self.children -> $child {
                %h<children>.push: $child.to-hash;
            }
            %h;
        }

        my class X::BadRole is Exception {
            has $.role-name;
            has $.node-name;
            method message() {
                "cannot resolve role '{ $!role-name }' specified for node '{ $!node-name }'";
            }
        }

        sub get-type(Mu:U $base-type, %h) {
            my $type = $base-type;
            if %h<does> -> $role-name {
                my $role = ::($role-name);
                if $role ~~ Failure {
                    CATCH {
                        default {
                            X::BadRole.new(:$role-name, node-name => %h<name>).throw;
                        }
                    }
                    require ::($role-name);
                    $role = ::($role-name);
                }
                if ::($role-name) !~~ Failure {
                    $type = $base-type but $role;
                }
                else {
                   X::BadRole.new(:$role-name, node-name => %h<name>).throw;
                }
            }
            %h<template> ?? $type but Template[$type] !! $type;
        }

        method children-from-hash(Parent:D: %h) {
            for %h<children>.list -> $child {
                my $child-node = do given $child<type> {
                    when 'directory' {
                        my $type = get-type(Directory,$child);
                        $type.from-hash(parent => self, $child);
                    }
                    when 'file' {
                        my $type = get-type(File, $child);
                        $type.from-hash(parent => self, $child);
                    }
                    default {
                        die 'DAFUQ!';
                    }
                }
                self.children.append: $child-node;
            }
        }

        method all-children() {
            gather {
                for self.children.list -> $child {
                    take $child;
                    if $child ~~ Parent {
                        for $child.all-children -> $child {
                            take $child;
                        }
                    }

                }
            }
        }

        method delete() returns Bool {
            my @res;
            for self.children -> $child {
                @res.append: $child.delete;
            }
            @res.append: self.IO.rmdir;
            so all(@res);
        }
    }

    role Node {
        has Str    $.name;
        has Parent $.parent;
        has Str    $.purpose;

        method path-parts() {
            my @parts = $!name;
            if $!parent.defined {
                @parts.prepend: $!parent.path-parts;
            }
            @parts;
        }

        method is-template() {
            False;
        }

        method path() returns Str {
            $*SPEC.catdir(self.path-parts);
        }

        method IO() returns IO::Path {
            self.path.IO;
        }

        method create() returns Bool {
            ...
        }

        method delete() returns Bool {
            ...
        }
    }

    class File does Node {
        method to-hash(File:D:) {
            my %h = type => 'file', name => $!name;
            %h;
        }

        method from-hash(%h, Parent:D :$parent) {
            self.new(:$parent,|%h);
        }

        method create() returns Bool {
            my $fh = self.IO.open(:w);
            $fh.close;
        }
        method delete() returns Bool {
            so self.IO.unlink;
        }

    }

    class Directory does Node does Parent {

        has Str $.what = 'directory';

        proto method generate(|c) { * }

        multi method generate(IO::Path:D :$root!, Parent :$parent!) {
            my $dir = self.new(name => $root.basename, :$parent);
            $dir.gather-children($root);
            $dir;
        }

        method from-hash(Directory:U: %h, Parent:D :$parent) {
            my %args = %h.pairs.grep({$_.key ~~ any(<name purpose>)}).Hash;
            my $dir = self.new(|%args, :$parent);
            $dir.children-from-hash(%h);
            $dir;
        }

        method create() returns Bool {
            my @res = self.IO.mkdir();
            for self.children -> $child {
                @res.append: $child.create;
            }
            so all(@res);
        }

    }

    class Layout does Parent {
        has Str  $.root = '.';
        has Str  $.what = 'layout';

        proto method generate(|c) { * }

        multi method generate(Str :$root = '.') returns Layout {
            samewith(root => $root.IO);
        }

        multi method generate(IO::Path:D :$root!) {
            my $layout = self.new(root => $root.basename);
            $layout.gather-children($root);
            $layout;
        }

        method from-hash(%h, :$root) {
            my $layout = self.new(:$root);
            $layout.children-from-hash(%h);
            $layout;
        }

        method to-json() {
            to-json(self.to-hash);
        }

        proto method from-json(|c) { * }

        multi method from-json(Layout:U: Str :$path!, |c) returns Layout {
            self.from-json(path => $path.IO, |c);
        }

        multi method from-json(Layout:U: IO::Path :$path!, |c) returns Layout {
            self.from-json($path.slurp, |c);
        }


        multi method from-json(Layout:U: Str $json, Str :$root) returns Layout {
            self.from-hash(from-json($json), :$root);
        }

        method path-parts() {
            $!root;
        }

        method nodes-for-purpose(Str $purpose) {
            self.all-children.grep({ $_.purpose.defined && $_.purpose eq $purpose });
        }

        method template-for-purpose(Str $purpose) returns Template {
            self.nodes-for-purpose($purpose).grep(*.is-template).first;
        }

        method create(Str :$root) returns Bool {
            $!root = $root.Str if $root.defined;

            if !$!root.IO.e {
                $!root.IO.mkdir;
            }
            my Bool @res;
            for self.children -> $child {
                @res.append: $child.create;
            }
            so all(@res);
        }

        method IO() returns IO::Path {
            $!root.IO;
        }
    }
}
# vim: expandtab shiftwidth=4 ft=perl6
