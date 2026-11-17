from appshell_org_nativehtmlkit_examples_greeter import Extension


def test_contract():
    plugin = Extension()
    context = {"data_dir": "/tmp", "extension_id": "org.nativehtmlkit.examples.greeter", "app_version": "0.1.0"}
    assert plugin.manifest(context)["api_version"] == 1
    assert plugin.page("overview", context)["title"] == 'Python Greeter'
    assert plugin.action("refresh", {}, {}, context)["refresh"] is True
