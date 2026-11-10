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

`Enterprise/` is licensed under the
[PolyForm Small Business License 1.0.0](Enterprise/LICENSE), with the additional permissions below.
Everything outside `Enterprise/` stays Apache-2.0.

- **Personal use and small businesses are free.** The licence counts a business as small when it
  has fewer than 100 people, employees and contractors together, and less than 1,000,000 US dollars
  (2019, adjusted for inflation) in revenue the year before.
- **Running Noodle without a configuration profile never needs a licence**, whatever the size of
  your organisation.
- **Larger organisations need a commercial licence from us to manage Noodle with configuration
  profiles.** To ask for one, email
  [pdp@gnucitizen.org](mailto:pdp@gnucitizen.org?subject=Noodle%20Enterprise%20licence) and tell
  us about your organisation.

**For now we grant commercial licences free of charge or on favourable terms**, so you can deploy
Noodle today without worrying about licence costs.

There are no licence keys and Noodle doesn't check for a licence: the app never blocks or limits
managed settings. The licence is how organisations that rely on Noodle help keep the project going;
it isn't meant to limit who can use Noodle.

### Additional permissions

In addition to the PolyForm Small Business License 1.0.0, the licensor gives everyone permission to
use the software in `Enterprise/`:

1. for personal purposes, not for the benefit of a company, whatever the size of the company you
   work for; and
2. as part of Noodle on any Mac where Noodle is not managed by a configuration profile.

## Contributing

Contributions to `Enterprise/` are welcome, on terms that let us license them under the PolyForm
Small Business License and under the commercial licences we grant. Contributions everywhere else
are Apache-2.0, as before.
