# Noodle Enterprise

Noodle is free and open source under the [Apache License 2.0](LICENSE). Organisations that
deploy it to their people's Macs can also manage it with a configuration profile from their device
management system (Jamf Pro, Kandji, Microsoft Intune, Mosyle and others): choose which harnesses
people can use, whether bots can run outside their sandbox, which tool connections, browsers,
computers and Hubs are allowed, and how Noodle updates.

That management is Noodle Enterprise. It lives in the [`Enterprise/`](Enterprise/) folder:

- the code that reads and enforces the profile's settings,
- the Jamf Pro schema and a sample configuration profile,
- the [deployment guide](Enterprise/Deployment.md) for administrators.

## Licence

`Enterprise/` has its own [licence](Enterprise/LICENSE), which is a draft pending legal review.
Anyone can read, change, build and test that code. Using it to deploy Noodle in an organisation
needs a Noodle enterprise licence from us. Everything outside `Enterprise/` stays Apache-2.0.

There are no licence keys and Noodle never checks for a licence: the app never blocks or limits
managed settings. The licence is how organisations that rely on Noodle help keep the project going;
it isn't meant to limit who can use Noodle.

**For now we grant enterprise licences free of charge or on favourable terms**, so your
organisation takes no risk by deploying Noodle now or later.

To ask for a licence, open an issue or a discussion on the
[Noodle project](https://github.com/pdparchitect/noodle) and tell us about your organisation.

## Contributing

Contributions to `Enterprise/` are welcome, on terms that let us license them under the
Enterprise licence as well. Contributions everywhere else are Apache-2.0, as before.
