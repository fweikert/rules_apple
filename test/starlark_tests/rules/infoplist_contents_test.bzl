# Copyright 2019 The Bazel Authors. All rights reserved.
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

"""Starlark test rules for debug symbols.

This test takes a target that propagates an AppleBundleInfo provider and a dictionary of keys and
values expected to be present in the Info.plist file generated by the rules.

This rule is meant to be used only for rules_apple tests and are considered implementation details
that may change at any time. Please do not depend on this rule.
"""

load(
    "//apple:providers.bzl",
    "AppleBinaryInfo",
    "AppleBundleInfo",
)
load(
    "//test/starlark_tests/rules:apple_verification_test.bzl",
    "apple_verification_transition",
)
load(
    "//test/starlark_tests/rules:output_group_test_support.bzl",
    "output_group_test_support",
)

def _infoplist_contents_test_impl(ctx):
    """Implementation of the plist_contents_test rule."""
    target_under_test = ctx.attr.target_under_test[0]
    if ctx.attr.output_group_name:
        if not ctx.attr.plist_test_file_shortpath:
            fail("`output_group_name` requires `plist_test_file_shortpath` to be set.")

        plist_file = output_group_test_support.output_group_file_from_target(
            output_group_name = ctx.attr.output_group_name,
            output_group_file_shortpath = ctx.attr.plist_test_file_shortpath,
            providing_target = target_under_test,
        )
    elif ctx.attr.plist_test_file_shortpath:
        fail("`plist_test_file_shortpath` requires `output_group_name` to be set at this time.")
    elif AppleBundleInfo in target_under_test:
        plist_file = target_under_test[AppleBundleInfo].infoplist
    elif AppleBinaryInfo in target_under_test:
        plist_file = target_under_test[AppleBinaryInfo].infoplist
    else:
        fail(("Target %s does not provide AppleBundleInfo or AppleBinaryInfo") % target_under_test.label)

    plist_path = plist_file.short_path

    test_lines = [
        "#!/bin/bash",
        "EXIT_CODE=0",
    ]

    for (key, value) in ctx.attr.expected_values.items():
        test_lines.extend([
            "VALUE=\"$(/usr/libexec/PlistBuddy -c \"Print {0}\" {1} 2>/dev/null)\"".format(
                key,
                plist_path,
            ),
            "if [[ -z \"$VALUE\" ]]; then",
            "  echo \"ERROR: Expected '{}' to be contained in the plist.\"".format(key),
            "  EXIT_CODE=1",
            "elif [[ \"$VALUE\" != {} ]]; then".format(value),
            "  echo \"ERROR: Expected '\"$VALUE\"' to match '{0}'\" for key '{1}'".format(
                value,
                key,
            ),
            "  EXIT_CODE=1",
            "fi",
        ])

    for key in ctx.attr.not_expected_keys:
        test_lines.extend([
            "VALUE=\"$(/usr/libexec/PlistBuddy -c \"Print {0}\" {1} 2>/dev/null)\"".format(
                key,
                plist_path,
            ),
            "if [[ -n \"$VALUE\" ]]; then",
            "  echo \"ERROR: Expected '{}' not to be contained in the plist.\"".format(key),
            "  EXIT_CODE=1",
            "fi",
        ])

    test_lines.extend([
        "if [[ \"$EXIT_CODE\" -eq 1 ]]; then",
        "  echo \"Actual contents were:\"",
        "  /usr/libexec/PlistBuddy -c \"Print\" {0} 2>/dev/null".format(plist_path),
        "fi",
    ])
    test_lines.append("exit $EXIT_CODE")

    test_script = ctx.actions.declare_file("{}_test_script".format(ctx.label.name))
    ctx.actions.write(test_script, "\n".join(test_lines), is_executable = True)

    xcode_config = ctx.attr._xcode_config[apple_common.XcodeVersionConfig]

    return [
        testing.ExecutionInfo(xcode_config.execution_info()),
        testing.TestEnvironment(apple_common.apple_host_system_env(xcode_config)),
        DefaultInfo(
            executable = test_script,
            runfiles = ctx.runfiles(
                files = [plist_file],
            ),
        ),
    ]

# Need a cfg for a transition on target_under_test, so can't use analysistest.make.
infoplist_contents_test = rule(
    _infoplist_contents_test_impl,
    attrs = {
        "build_type": attr.string(
            default = "simulator",
            doc = """
Type of build for the target under test. Possible values are `simulator` or `device`.
Defaults to `simulator`.
""",
            values = ["simulator", "device"],
        ),
        "compilation_mode": attr.string(
            default = "fastbuild",
            doc = """
Possible values are `fastbuild`, `dbg` or `opt`. Defaults to `fastbuild`.
https://docs.bazel.build/versions/master/user-manual.html#flag--compilation_mode
""",
            values = ["fastbuild", "opt", "dbg"],
        ),
        "apple_generate_dsym": attr.bool(
            default = False,
            doc = """
If true, generates .dSYM debug symbol bundles for the target(s) under test.
""",
        ),
        "macos_cpus": attr.string_list(
            default = ["x86_64"],
            doc = """
List of MacOS CPU's to use for test under target.
https://docs.bazel.build/versions/main/command-line-reference.html#flag--macos_cpus
""",
        ),
        "target_under_test": attr.label(
            cfg = apple_verification_transition,
            doc = "Target containing an Info.plist file to verify.",
            mandatory = True,
        ),
        "expected_values": attr.string_dict(
            default = {},
            doc = """
Dictionary of plist keys and expected values for that key. This test will fail if the key does not
exist or if it it doesn't match the value. * can be used as a wildcard, similar to how it works in
shell scripts.
""",
        ),
        "not_expected_keys": attr.string_list(
            default = [],
            doc = "Array of plist keys that should not exist. The test will fail if the key exists.",
        ),
        "output_group_name": attr.string(
            doc = """
Optional. The name of the output group that has the plist file to verify. Requires setting
`plist_test_file_shortpath`.
""",
        ),
        "plist_test_file_shortpath": attr.string(
            doc = """
Optional. A short path to the plist file to test with `expected_values`. Requires setting
`output_group_name`. If this is not set, the default `infoplist` referenced by the AppleBundleInfo
provider will be used instead.
""",
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
        "_xcode_config": attr.label(
            default = configuration_field(
                name = "xcode_config_label",
                fragment = "apple",
            ),
        ),
    },
    fragments = ["apple"],
    test = True,
)
