# Frequently Asked Questions

## Why should I use this instead of Power Platform Pipelines?

Power Platform Pipelines is a great start into the world of structured ALM for Dataverse project, but out of the box, has many limitations that will bite when you want to go further.

PPP can be extended to allow some of this, by then the recommendation is to use it as a hybrid with AzDO Pipelines. We think that is it makes sense to just use AzDO or GitHub at this point, as PPP doesn't offer much once you have those.

Read more about Rob's thought's on this here - [Why Power Platform Pipelines isn't powerful enough for many pro projects](https://rnwood.co.uk/posts/why-power-platform-pipelines-isn-t-powerful-enough-for-many-pro-projects/).


## Why would I use this instead of my own Pipelines/Workflows?

Getting a complete and working ALM setup for Dataverse using AzDO/GitHub is a lot more complex than it initially seems. You'll start with just a few steps in a pipeline using the Microsoft Power Platform Build Tools tasks. It'll work great until you hit all the edge-cases and complex things:

- Handling environment variables and connection references
- Activating workflows properly
- Handling install vs upgrade for each solution depending on current state of environment (ensuring you can deploy to empty envs as well as to existing ones and ensuring obsolete components get correctly deleted)
- Automating things beyond just importing solutions  - important for your work to work.

At that point your custom setup will be incrementally more complex, or you'll be investing hours in processes that workaround those imperfections/gaps - meaning the benefits of ALM are evaporating quickly.

ALM4Datverse brings a standard implementation you can just re-use and configure (plus extend if needed) for all the core challenges that come up typically as well as a set of standard processes and documentation to guide you.


## Why do I need to set up 2 source control repos instead of just 1?

The 'shared' repo design put as much as possible into a repo that isn't your product's actual repo, and leaves only pipeline/workflow stubs and configuration in that repo. This allows:

- Easy updates of ALM4Dataverse to fix bugs and add features
- Multiple projects can share the same shared repo - no duplication of complex logic across repos if you have many (less maintenance).