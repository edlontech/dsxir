# Changelog

## [0.3.0](https://github.com/edlontech/dsxir/compare/dsxir-v0.2.0...dsxir-v0.3.0) (2026-05-25)


### Features

* **copro:** add COPRO optimizer ([c38747a](https://github.com/edlontech/dsxir/commit/c38747a28e174dfcc6de35a42569a9b48fdc2390))
* **pot:** add Program of Thought and CodeAct predictors ([9dda142](https://github.com/edlontech/dsxir/commit/9dda142cfc22df3edb963384ae3a66fd845b29af))


### Bug Fixes

* Improved errors feedback ([dd86ef4](https://github.com/edlontech/dsxir/commit/dd86ef4815e4f738152371fb0e9d8b7091d16bc7))

## [0.2.0](https://github.com/edlontech/dsxir/compare/dsxir-v0.1.0...dsxir-v0.2.0) (2026-05-20)

### Features

* add KNNFewShot optimizer for per-call dynamic demo selection ([fc0a058](https://github.com/edlontech/dsxir/commit/fc0a058de24e034a492846f00840716e101ebfa1))
* add MIPROv2 optimizer with TPE search and grounded proposer ([fc8edea](https://github.com/edlontech/dsxir/commit/fc8edea44e9bb9299b8c818e85a9720086fa6f68))
* add OptimizerSession with checkpointing, pause/resume, and MIPROv2/BFS retrofit ([b67e2c6](https://github.com/edlontech/dsxir/commit/b67e2c6fdf856fe20ee960b5e0a23b738a701ab2))
* add runtime programs ([b162b3d](https://github.com/edlontech/dsxir/commit/b162b3d3a3899f492059dd9444b44b4a4e4aae65))
* **gepa:** add reflective Pareto-frontier optimizer ([0edcd58](https://github.com/edlontech/dsxir/commit/0edcd58dad4263d5179c24c43e573a8d3faa4038))
* make sycophant optional ([ec2609d](https://github.com/edlontech/dsxir/commit/ec2609def76043cecae02f6fef3d138147f7d531))


### Bug Fixes

* **settings:** make run/2 globals override process-local ([c49c0ab](https://github.com/edlontech/dsxir/commit/c49c0ab345f509fa37e156bb3f85c6612a22f5e6))

## [0.1.0](https://github.com/edlontech/dsxir/compare/dsxir-v0.0.1...dsxir-v0.1.0) (2026-05-13)


### Features

* Added inspect protocol for the project structures ([cc707d3](https://github.com/edlontech/dsxir/commit/cc707d308879192a2b95e14d157872b562ecd7fa))
* evaluate, optimizer, and save/load ([f5c0cce](https://github.com/edlontech/dsxir/commit/f5c0cce79cba3c7014cc4bde68c9ab82ea2e581b))
* Implement CallContext, Quirks validation and Docs ([2d3bc8f](https://github.com/edlontech/dsxir/commit/2d3bc8f1f8c5c2b4c5dc101aeea79bc7dd41b129))
* Implemented Object x Chat responses ([1c884f0](https://github.com/edlontech/dsxir/commit/1c884f09868b6df351263944006c996fe9b86c41))
* Implementing History ([d426fbc](https://github.com/edlontech/dsxir/commit/d426fbc19726bd92de7e0d7746605b07e7d05350))
* Implementing predictors and signatures ([9df1546](https://github.com/edlontech/dsxir/commit/9df15463987d2473302a7aca0d014756ee0b5d39))
* Implementing Sycophant responses ([ecd9597](https://github.com/edlontech/dsxir/commit/ecd9597bfe2ae76d37d272bda5764c37aecb3179))
* Improved Errors ([d8a8a4d](https://github.com/edlontech/dsxir/commit/d8a8a4d85ac751fb10a6dc1e18937b1d661ef898))
* Initial Structure ([5ae36d0](https://github.com/edlontech/dsxir/commit/5ae36d08af310732cea42b62e6f377ac84d46c55))
* react predictor, tool primitive, history value type, embed callback, in-memory retriever ([7e97415](https://github.com/edlontech/dsxir/commit/7e97415ddbb361464478b0cf856fa8e19e0159ed))
* trace, with_trace, and BootstrapFewShot optimizer ([7ce2c12](https://github.com/edlontech/dsxir/commit/7ce2c1282396cf96c0ddaaf8b4a9eba4ecc682ff))


### Bug Fixes

* Fixed formatter for the DSL ([2edfd72](https://github.com/edlontech/dsxir/commit/2edfd725d8e6db6f774562f2756fe938748a293f))
* per-predictor demo slotting and CoT/ReAct save-load ([e6f5c34](https://github.com/edlontech/dsxir/commit/e6f5c3471cfa970e5f56171abe465db11351167b))
