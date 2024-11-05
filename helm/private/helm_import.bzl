"""Helm rules for managing external dependencies"""

load("//helm:providers.bzl", "HelmPackageInfo")

def _helm_import_impl(ctx):
    if ctx.attr.chart:
        # Use the provided chart file
        chart_file = ctx.file.chart
    else:
        # Need to download the chart
        chart_name = ctx.attr.chart_name or ctx.label.name
        version = ctx.attr.version
        repository = ctx.attr.repository
        url = ctx.attr.url
        sha256 = ctx.attr.sha256

        if not chart_name:
            fail("'chart_name' must be specified.")

        if url:
            # Option 1: Download the chart tarball directly from the given URL
            chart_file_name = url.split("/")[-1]
            chart_url = url
            chart_file = ctx.actions.declare_file(chart_file_name)

            # Download the chart
            ctx.actions.run(
                outputs = [chart_file],
                executable = "curl -L -o \"$1\" \"$2\"",
                arguments = [chart_file.path, chart_url],
                execution_requirements = {"requires-network": "1"},
                progress_message = "Downloading chart from {}".format(chart_url),
            )
        elif repository and version:
            # Option 2: Download index.yaml and parse it to find the chart URL
            index_yaml_file = ctx.actions.declare_file("index.yaml")
            chart_file_name = "{}-{}.tgz".format(chart_name, version)
            chart_file = ctx.actions.declare_file(chart_file_name)

            # Download index.yaml
            ctx.actions.run(
                outputs = [index_yaml_file],
                executable = "curl -L -o \"$1\" \"$2\"",
                arguments = [index_yaml_file.path, repository.rstrip("/") + "/index.yaml"],
                execution_requirements = {"requires-network": "1"},
                progress_message = "Downloading index.yaml from {}".format(repository),
            )

            # Parse index.yaml to find chart URL
            def _parse_index_yaml_action(action_ctx):
                index_content = action_ctx.file.index_yaml_file.content.decode("utf-8")
                chart_url = _find_chart_url(index_content, chart_file_name, repository)
                action_ctx.file_chart_url.write(chart_url)

            chart_url_file = ctx.actions.declare_file("chart_url.txt")
            ctx.actions.run(
                inputs = [index_yaml_file],
                outputs = [chart_url_file],
                executable = ctx.executable._parse_index_yaml_tool,
                arguments = [index_yaml_file.path, chart_file_name, repository, chart_url_file.path],
                use_default_shell_env = True,
                progress_message = "Parsing index.yaml to find chart URL",
            )

            # Download the chart using the chart URL
            ctx.actions.run(
                inputs = [chart_url_file],
                outputs = [chart_file],
                executable = "curl -L -o \"$1\" \"$2\"",
                arguments = [chart_file.path, "$(cat {})".format(chart_url_file.path)],
                execution_requirements = {"requires-network": "1"},
                progress_message = "Downloading chart from URL",
            )
        else:
            fail("Either 'chart' or 'url', or 'chart_name', 'version', and 'repository' must be specified.")

    metadata_output = ctx.actions.declare_file(ctx.label.name + ".metadata.json")
    ctx.actions.write(
        output = metadata_output,
        content = json.encode_indent(struct(
            name = ctx.label.name,
            version = ctx.attr.version,
        ), indent = " " * 4),
    )

    return [
        DefaultInfo(
            files = depset([chart_file]),
            runfiles = ctx.runfiles([chart_file]),
        ),
        HelmPackageInfo(
            chart = chart_file,
            images = [],
            metadata = metadata_output,
        ),
    ]

helm_import = rule(
    implementation = _helm_import_impl,
    doc = "A rule that allows pre-packaged Helm charts to be used within Bazel.",
    attrs = {
        "chart": attr.label(
            doc = "A Helm chart's `.tgz` file.",
            allow_single_file = [".tgz"],
        ),
        "chart_name": attr.string(
            doc = "Chart name to import.",
        ),
        "version": attr.string(
            doc = "The version fo the helm chart",
        ),
        "repository": attr.string(
            doc = "Chart repository URL where to locate the requested chart.",
        ),
        "url": attr.string(
            doc = "The URL where the chart can be directly downloaded.",
        ),
        "sha256": attr.string(
            doc = "The expected SHA-256 hash of the chart to verify integrity.",
        ),
    },
)

def _find_chart_url(repo_file_contents, chart_file, repository):
    lines = repo_file_contents.splitlines()
    for line in lines:
        line = line.lstrip(" ")
        if line.startswith("-") and line.endswith(chart_file):
            url = line.lstrip("-").lstrip(" ")
            if url == chart_file:
                return "{}/{}".format(repository.rstrip("/"), url)
            if url.startswith("http") and url.endswith("/{}".format(chart_file)):
                return url
    fail("cannot find {} in index.yaml".format(chart_file))

_HELM_DEP_BUILD_FILE = """\
load("@rules_helm//helm:defs.bzl", "helm_import")

helm_import(
    name = "{chart_name}",
    chart = "{chart_file}",
    visibility = ["//visibility:public"],
)

alias(
    name = "{repository_name}",
    actual = ":{chart_name}",
    visibility = ["//visibility:public"],
)
"""

def _helm_import_repository_impl(repository_ctx):
    chart_name = repository_ctx.attr.chart_name or repository_ctx.name

    if repository_ctx.attr.url:
        chart_url = repository_ctx.attr.url
    else:
        if not repository_ctx.attr.version:
            fail("`version` is needed to locate charts")

        repo_yaml = "index.yaml"
        repository_ctx.download(
            output = repo_yaml,
            url = "{}/{}".format(
                repository_ctx.attr.repository,
                repo_yaml,
            ),
        )
        file_name = "{}-{}.tgz".format(
            chart_name,
            repository_ctx.attr.version,
        )

        repo_def = repository_ctx.read(repo_yaml)
        chart_url = _find_chart_url(repo_def, file_name, repository_ctx.attr.repository)

    # Parse the chart file name from the URL
    _, _, chart_file = chart_url.rpartition("/")

    repository_ctx.file("BUILD.bazel", content = _HELM_DEP_BUILD_FILE.format(
        chart_name = chart_name,
        chart_file = chart_file,
        repository_name = repository_ctx.name,
    ))

    result = repository_ctx.download(
        output = repository_ctx.path(chart_file),
        url = chart_url,
        sha256 = repository_ctx.attr.sha256,
    )

    return {
        "chart_name": repository_ctx.attr.chart_name,
        "name": repository_ctx.name,
        "repository": repository_ctx.attr.repository,
        "sha256": result.sha256,
        "url": chart_url,
        "version": repository_ctx.attr.version,
    }

helm_import_repository = repository_rule(
    implementation = _helm_import_repository_impl,
    doc = "A rule for fetching external Helm charts from an arbitrary repository.",
    attrs = {
        "chart_name": attr.string(
            doc = "Chart name to import.",
        ),
        "repository": attr.string(
            doc = "Chart repository url where to locate the requested chart.",
            mandatory = True,
        ),
        "sha256": attr.string(
            doc = "The expected SHA-256 hash of the chart imported.",
        ),
        "url": attr.string(
            doc = "The url where the chart can be directly downloaded.",
        ),
        "version": attr.string(
            doc = "Specify a version constraint for the chart version to use.",
        ),
    },
)
