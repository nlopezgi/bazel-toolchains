# Copyright 2017 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Rules for generating toolchain configs for a Docker container.

Exposes the docker_autoconfigure rule that does the following:
- Receive a base container as main input. Base container could have a desired
  set of toolchains (i.e., a C compiler, C libraries, java, python, zip, and
  other tools) installed.
- Optionally, install more debian packages in the base container (any packages
  that might be needed by Bazel not installed in your container).
- Optionally, install a given Bazel version on the container.
- Extend the container to install sources for a project.
- Run a bazel command to build one or more targets from
  remote repositories, inside the container.
- Copy toolchain configs (outputs of remote repo targets) produced
  from the execution of Bazel inside the container to the host.

Example:

  docker_toolchain_autoconfig(
      name = "my-autoconfig-rule",
      base = "@my_image//image:image.tar",
      bazel_version = "0.10.0",
      config_repos = ["local_config_cc", "<some_other_skylark_repo>"],
      git_repo = "https://github.com/some_git_repo",
      env = {
          ... Dictionary of env variables to configure Bazel properly
              for the container, see environments.bzl for examples.
      },
      packages = [
          "package_1",
          "package_2=version",
      ],
      # Any additional debian repos and keys needed to install packages above,
      # not needed if no packages are installed.
      additional_repos = [
          "deb http://deb.debian.org/debian jessie-backports main",
      ],
      keys = [
          "@some_gpg//file",
      ],
  )

Add to your WORKSPACE file the following:

  load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive", "http_file")

  http_archive(
    name = "bazel_toolchains",
    urls = [
      "https://mirror.bazel.build/github.com/bazelbuild/bazel-toolchains/archive/<latest_release>.tar.gz",
      "https://github.com/bazelbuild/bazel-toolchains/archive/<latest_release>.tar.gz",
    ],
    strip_prefix = "bazel-toolchains-<latest_commit>",
    sha256 = "<sha256>",
  )

  load(
    "@bazel_toolchains//repositories:repositories.bzl",
    bazel_toolchains_repositories = "repositories",
  )

  bazel_toolchains_repositories()

  load(
      "@io_bazel_rules_docker//repositories:repositories.bzl",
      container_repositories = "repositories",
  )

  container_repositories()

  load(
      "@io_bazel_rules_docker//container:container.bzl",
      "container_pull",
  )

  # Pulls the my_image used as base for example above
  container_pull(
      name = "my_image",
      digest = "sha256:<sha256>",
      registry = "<registry>",
      repository = "<repo>",
  )

  # GPG file used by example above
  http_file(
    name = "some_gpg",
    sha256 = "<sha256>",
    url = "<URL>",
  )

For values of <latest_release> and other placeholders above, please see
the WORKSPACE file in this repo.

To use the rule run:

  bazel build //<location_of_rule>:my-autoconfig-rule

Once rule finishes running the file my-autoconfig-rule_output.tar
will be created with all toolchain configs generated by
"local_config_cc" and "<some_other_skylark_repo>".

Known issues:

 - 'name' of rule must conform to docker image naming standards
 - Rule cannot be placed in the BUILD file at the root of a project
"""

load("@bazel_skylib//lib:dicts.bzl", "dicts")
load("@io_bazel_rules_docker//docker/toolchain_container:toolchain_container.bzl", "toolchain_container")
load(
    "@io_bazel_rules_docker//container:container.bzl",
    _container = "container",
)
load("@io_bazel_rules_docker//docker/util:run.bzl", _extract = "extract")

# External folder is set to be deprecated, lets keep it here for easy
# refactoring
# https://github.com/bazelbuild/bazel/issues/1262
_EXTERNAL_FOLDER_PREFIX = "external/"

# Name of the current workspace
_WORKSPACE_NAME = "bazel_toolchains"

_WORKSPACE_PREFIX = "@" + _WORKSPACE_NAME + "//"

# Default cc project to use if no git_repo is provided.
_DEFAULT_AUTOCONFIG_PROJECT_PKG_TAR = _WORKSPACE_PREFIX + "rules:cc-sample-project-tar"

# Filetype to restrict inputs
tar_filetype = [
    ".tar",
    ".tar.xz",
]

def _docker_toolchain_autoconfig_impl(ctx):
    """Implementation for the docker_toolchain_autoconfig rule.

    Args:
      ctx: context. See docker_toolchain_autoconfig below for details
          of what this ctx must include
    """
    bazel_config_dir = "/bazel-config"
    project_repo_dir = "project_src"
    output_dir = bazel_config_dir + "/autoconf_out"
    name = ctx.attr.name
    outputs_tar = ctx.outputs.output_tar.basename

    # Command to retrieve the project from github if requested.
    clone_repo_cmd = "cd ."
    if ctx.attr.git_repo:
        clone_repo_cmd = ("cd " + bazel_config_dir + " && git clone " +
                          ctx.attr.git_repo + " " + project_repo_dir)

    repo_dir = bazel_config_dir + "/" + project_repo_dir
    if ctx.attr.repo_pkg_tar:
        # if package tar was used then the command should expand it
        clone_repo_cmd = ("mkdir %s && tar -xf /%s -C %s " %
                          (repo_dir, ctx.file.repo_pkg_tar.basename, repo_dir))

    # if mount_project was selected, we'll mount it using docker_run_flags
    docker_run_flags = [""]
    if ctx.attr.mount_project:
        mount_project = ctx.attr.mount_project
        mount_project = ctx.expand_make_variables("mount_project", mount_project, {})
        target = mount_project + ":" + repo_dir + ":ro"
        docker_run_flags = ["-v", target]

    # Command to install custom Bazel version (if requested)
    install_bazel_cmd = "cd ."
    if ctx.attr.use_bazel_head:
        # If use_bazel_head was requested, we clone the source code from github and compile
        # it using the release version with "bazel build //src:bazel".
        install_bazel_cmd = "/install_bazel_head.sh"
    elif ctx.attr.bazel_version:
        # If a specific Bazel and Bazel RC version is specified, install that version.
        bazel_url = "https://releases.bazel.build/" + ctx.attr.bazel_version
        if ctx.attr.bazel_rc_version:
            bazel_url += ("/rc" + ctx.attr.bazel_rc_version +
                          "/bazel-" + ctx.attr.bazel_version + "rc" +
                          ctx.attr.bazel_rc_version)
        else:
            bazel_url += "/release/bazel-" + ctx.attr.bazel_version
        if not ctx.attr.build_bazel_src:
            bazel_url += "-installer-linux-x86_64.sh"
            install_bazel_cmd = "/install_bazel_version.sh " + bazel_url
        else:
            bazel_url += "-dist.zip"
            install_bazel_cmd = "/build_bazel_version.sh " + bazel_url

    # Command to recursively convert soft links to hard links in the config_repos
    deref_symlinks_cmd = []
    for config_repo in ctx.attr.config_repos:
        symlinks_cmd = ("find $(bazel info output_base)/" +
                        _EXTERNAL_FOLDER_PREFIX + config_repo +
                        " -type l -exec bash -c 'ln -f \"$(readlink -m \"$0\")\" \"$0\"' {} \;")
        deref_symlinks_cmd.append(symlinks_cmd)
    deref_symlinks_cmd = " && ".join(deref_symlinks_cmd)

    # Command to copy produced toolchain configs to a tar at the root
    # of the container.
    copy_cmd = ["mkdir " + output_dir]
    for config_repo in ctx.attr.config_repos:
        src_dir = "$(bazel info output_base)/" + _EXTERNAL_FOLDER_PREFIX + config_repo
        copy_cmd.append("cp -dr " + src_dir + " " + output_dir)
    copy_cmd.append("tar -cf /" + outputs_tar + " -C " + output_dir + "/ . ")
    output_copy_cmd = " && ".join(copy_cmd)

    # Command to run autoconfigure targets.
    bazel_cmd = "cd " + bazel_config_dir + "/" + project_repo_dir
    if ctx.attr.use_default_project:
        bazel_cmd += " && touch WORKSPACE && mv BUILD.sample BUILD"

    # For each config repo we run the target @<config_repo>//...
    bazel_targets = "@" + "//... @".join(ctx.attr.config_repos) + "//..."
    bazel_cmd += " && bazel build " + bazel_targets

    # Command to run to clean up after autoconfiguration.
    # we start with "cd ." to make sure in case of failure everything after the
    # ";" will be executed
    clean_cmd = "cd . ; bazel clean"
    if ctx.attr.use_default_project:
        clean_cmd += " && rm WORKSPACE"
    if ctx.attr.git_repo:
        clean_cmd += " && cd " + bazel_config_dir + " && rm -drf " + project_repo_dir

    install_sh = ctx.actions.declare_file(name + "_install.sh")
    ctx.actions.write(
        output = install_sh,
        content = "\n ".join([
            "set -ex",
            "echo === Starting docker autoconfig ===",
            ctx.attr.setup_cmd,
            install_bazel_cmd,
            "echo === Cloning / expand project repo ===",
            clone_repo_cmd,
            "echo === Running Bazel autoconfigure command ===",
            bazel_cmd,
            "echo === Copying outputs ===",
            deref_symlinks_cmd,
            output_copy_cmd,
            "echo === Cleaning up ===",
            clean_cmd,
        ]),
    )

    # Include the repo_pkg_tar if needed
    files = [install_sh] + ctx.files._installers
    if ctx.attr.repo_pkg_tar:
        files += [ctx.file.repo_pkg_tar]

    image_tar = ctx.actions.declare_file(name + ".tar")

    # TODO(nlopezgi): fix upstream issue that output_executable is required
    load_image_sh_file = ctx.actions.declare_file(name + "load.sh")
    _container.image.implementation(
        ctx,
        files = files,
        output_executable = load_image_sh_file,
        output_tarball = image_tar,
        workdir = bazel_config_dir,
    )

    # Commands to run script to create autoconf results, output stderr to log file
    # add the log file to a tar file and append the output.tar to that same tar file
    commands = []
    commands += ["/" + ctx.attr.name + "_install.sh 2> /" + ctx.attr.name + ".log"]
    commands += ["tar -cf /extract.tar /" + ctx.attr.name + ".log"]
    commands += [
        ("if [ -f /" + outputs_tar + " ]; " +
         "then tar -rf /extract.tar /" + outputs_tar + "; fi"),
    ]

    print(("\n== Docker autoconfig will run. ==\n" +
           "To debug any errors run:\n" +
           "> docker run -it {mount_flags} <image_id> bash\n" +
           "Where <image_id> is the image id printed out by the " +
           "{name}_extract.tar rule.\n" +
           "Then run:\n>/{run_cmd}\n" +
           "from inside the container.").format(
        mount_flags = " ".join(docker_run_flags),
        name = ctx.attr.name,
        run_cmd = install_sh.basename,
    ))

    extract_tar_file = ctx.actions.declare_file(name + "_extract.tar")
    _extract.implementation(
        ctx,
        name = ctx.attr.name + "_extract",
        image = image_tar,
        docker_run_flags = docker_run_flags,
        commands = commands,
        extract_file = "/extract.tar",
        script_file = ctx.actions.declare_file(ctx.attr.name + ".build"),
        output_file = extract_tar_file,
    )

    # Extracts the two outputs produced by this rule (outputs.tar + log file)
    # from the tar file extracted from the container in the rule above
    ctx.actions.run_shell(
        inputs = [extract_tar_file],
        outputs = [ctx.outputs.output_tar, ctx.outputs.log],
        command = ("tar -C %s -xf %s" % (ctx.outputs.output_tar.dirname, extract_tar_file.path)),
    )

docker_toolchain_autoconfig_ = rule(
    attrs = dicts.add(_container.image.attrs, {
        "additional_repos": attr.string_list(),
        "bazel_rc_version": attr.string(),
        "bazel_version": attr.string(),
        "config_repos": attr.string_list(default = ["local_config_cc"]),
        "git_repo": attr.string(),
        "build_bazel_src": attr.bool(default = False),
        "keys": attr.string_list(),
        "mount_project": attr.string(),
        "packages": attr.string_list(),
        "repo_pkg_tar": attr.label(allow_single_file = tar_filetype),
        "setup_cmd": attr.string(default = "cd ."),
        "test": attr.bool(default = True),
        "use_bazel_head": attr.bool(default = False),
        "use_default_project": attr.bool(default = False),
        # TODO(nlopezgi): fix upstream attr declaration that is missing repo name
        "_extract_image_id": attr.label(
            default = Label("@io_bazel_rules_docker//contrib:extract_image_id"),
            cfg = "host",
            executable = True,
            allow_files = True,
        ),
        "_extract_tpl": attr.label(
            default = Label("@io_bazel_rules_docker//docker/util:extract.sh.tpl"),
            allow_single_file = True,
        ),
        "_installers": attr.label(default = ":bazel_installers", allow_files = True),
    }),
    outputs = dicts.add(_container.image.outputs, {
        "log": "%{name}.log",
        "output_tar": "%{name}_outputs.tar",
    }),
    toolchains = ["@io_bazel_rules_docker//toolchains/docker:toolchain_type"],
    implementation = _docker_toolchain_autoconfig_impl,
)

# Attributes below are expected in ctx, but should not be provided
# in the BUILD file.
reserved_attrs = [
    "use_default_project",
    "files",
    "debs",
    "repo_pkg_tar",
    # all the attrs from docker_build we dont want users to set
    "directory",
    "tars",
    "legacy_repository_naming",
    "legacy_run_behavior",
    "docker_run_flags",
    "mode",
    "symlinks",
    "entrypoint",
    "cmd",
    "user",
    "labels",
    "ports",
    "volumes",
    "workdir",
    "repository",
    "label_files",
    "label_file_strings",
    "empty_files",
    "build_layer",
    "create_image_config",
    "sha256",
    "incremental_load_template",
    "join_layers",
    "extract_config",
]

# Attrs expected in the BUILD rule
required_attrs = [
    "base",
]

def docker_toolchain_autoconfig(**kwargs):
    """Generate toolchain configs for a docker container.

    This rule produces a tar file with toolchain configs produced from the
    execution of targets in skylark remote repositories. Typically, this rule is
    used to produce toolchain configs for the local_config_cc repository.
    This repo (as well as others, depending on the project) contains generated
    toolchain configs that Bazel uses to properly use a toolchain. For instance,
    the local_config_cc repo generates a cc_toolchain rule.

    The toolchain configs that this rule produces, can be used to, for
    instance, use a remote execution service that runs actions inside docker
    containers.

    All the toolchain configs published in the bazel-toolchains
    repo (https://github.com/bazelbuild/bazel-toolchains/) have been produced
    using this rule.

    This rule is implemented by extending the container_image rule in
    https://github.com/bazelbuild/rules_docker. The rule installs debs packages
    to run bazel (using the package manager rules offered by
    https://github.com/GoogleContainerTools/base-images-docker).
    The rule creates the container with a command that pulls a repo from github,
    and runs bazel build for a series of remote repos. Files generated in these
    repos are copied to a mount point inside the Bazel output tree.

    Args:
      **kwargs:
            Required Args
            name: A unique name for this rule.
            base: Docker image base - optionally with all tools pre-installed
                  for which a configuration will be generated. Packages can also
                  be installed by listing them in the 'packages' attriute.
            Default Args:
            config_repos: a list of remote repositories. Autoconfig will run
                targets in each of these remote repositories and copy all
                contents to the mount point.
            env: Dictionary of env variables for Bazel / project specific
                 autoconfigure
            git_repo: A git repo with the sources for the project to be used for
                autoconfigure. If no git_repo is passed, autoconfig will run
                with a sample c++ project.
            mount_project: mounts a directory passed in an absolute path as the
                           project to use for autoconfig. Cannot be used if
                           git_repo is passed. Make variable substitution is
                           enabled, so use:
                            mount_project = "$(mount_project)",
                           and then run:
                            bazel build <autoconf target> --define mount_project=$(realpath .)
                           from the root of the project to mount it as the
                           project to use for autoconfig.
            bazel_version: a specific version of Bazel used to generate toolchain
                configs. Format: x.x.x
            bazel_rc_version: a specific version of Bazel release candidate used to
                generate toolchain configs. Input "2" if you would like to use rc2.
            use_bazel_head = Download bazel head from github, compile it and use it
                to run autoconfigure targets.
            build_bazel_src: Default False, if set to True Bazel will be built from
                source as opposed to installed using pre-compiled binaries.
            setup_cmd: a customized command that will run as the very first command
                inside the docker container.
            packages: list of packages to fetch and install in the base image.
            additional_repos: list of additional debian package repos to use,
                in sources.list format.
            keys: list of additional gpg keys to use while downloading packages.
            test: a boolean which specifies whether a test target for this
                docker_toolchain_autoconfig will be added.
                If True, a test target with name {name}_test will be added.
                The test will build this docker_toolchain_autoconfig target, run the
                output script, and check the toolchain configs for the c++ auto
                generated config exist.
    """
    for reserved in reserved_attrs:
        if reserved in kwargs:
            fail("reserved for internal use by docker_toolchain_autoconfig macro", attr = reserved)

    for required in required_attrs:
        if required not in kwargs:
            fail("required for docker_toolchain_autoconfig", attr = required)

    # Input validations
    use_bazel_head = "use_bazel_head" in kwargs and kwargs["use_bazel_head"]
    build_bazel_src = "build_bazel_src" in kwargs and kwargs["build_bazel_src"]
    if use_bazel_head and ("bazel_version" in kwargs or "bazel_rc_version" in kwargs):
        fail("Only one of use_bazel_head or a combination of bazel_version and" +
             "bazel_rc_version can be set at a time.")
    if use_bazel_head and build_bazel_src:
        fail("use_bazel_head cannot be set when build_bazel_src is set to True.")
    if build_bazel_src and "bazel_rc_version" in kwargs:
        fail("bazel_rc_version cannot be set when build_bazel_src is set to True.")
    if build_bazel_src and not "bazel_version" in kwargs:
        fail("bazel_version must be set when build_bazel_src is set to True.")

    packages_is_empty = "packages" not in kwargs or kwargs["packages"] == []

    if packages_is_empty and "additional_repos" in kwargs:
        fail("'additional_repos' can only be specified when 'packages' is not empty.")
    if packages_is_empty and "keys" in kwargs:
        fail("'keys' can only be specified when 'packages' is not empty.")

    if "git_repo" in kwargs and "mount_project" in kwargs:
        fail("'git_repo' cannot be used with 'mount_project'.")

    # If a git_repo or mount_project was not provided
    # use the default autoconfig project
    if "git_repo" not in kwargs and "mount_project" not in kwargs:
        kwargs["repo_pkg_tar"] = _DEFAULT_AUTOCONFIG_PROJECT_PKG_TAR
        kwargs["use_default_project"] = True
    kwargs["files"] = [
        _WORKSPACE_PREFIX + "rules:install_bazel_head.sh",
        _WORKSPACE_PREFIX + "rules:install_bazel_version.sh",
        _WORKSPACE_PREFIX + "rules:build_bazel_version.sh",
    ]

    # Do not install packags if 'packages' is not specified or is an empty list.
    if not packages_is_empty:
        # "additional_repos" and "keys" are optional for docker_toolchain_autoconfig,
        # but required for toolchain_container". Use empty lists as placeholder.
        if "additional_repos" not in kwargs:
            kwargs["additional_repos"] = []
        if "keys" not in kwargs:
            kwargs["keys"] = []

        # Install packages in the base image.
        toolchain_container(
            name = kwargs["name"] + "_image",
            base = kwargs["base"],
            packages = kwargs["packages"],
            additional_repos = kwargs["additional_repos"],
            keys = kwargs["keys"],
        )

        # Use the image with packages installed as the new base for autoconfiguring.
        kwargs["base"] = ":" + kwargs["name"] + "_image.tar"

    if "test" in kwargs and kwargs["test"] == True:
        # Create a test target for the current docker_toolchain_autoconfig target,
        # which builds this docker_toolchain_autoconfig target, runs the output
        # script, and checks the toolchain configs for the c++ auto generated config
        # exist.
        native.sh_test(
            name = kwargs["name"] + "_test",
            size = "medium",
            timeout = "long",
            srcs = ["@bazel_toolchains//tests/config:autoconfig_test.sh"],
            data = [":" + kwargs["name"] + "_outputs.tar"],
        )

    docker_toolchain_autoconfig_(**kwargs)
