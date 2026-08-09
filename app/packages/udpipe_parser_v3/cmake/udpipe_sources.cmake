# UDPipe 1.4.0 is vendored from https://github.com/ufal/udpipe at tag v1.4.0.
# Keep the source selection shared by Windows, Android and the training tool.
set(UDPIPE_SOURCE_ROOT
  "${CMAKE_CURRENT_LIST_DIR}/../third_party/udpipe/src")

# This is the exact upstream UDPIPE_OBJECTS list. Do not glob the source tree:
# it also contains standalone encoders and tools which are intentionally not
# part of libudpipe and some of which do not compile as library translation
# units.
set(UDPIPE_RELATIVE_SOURCES
  morphodita/derivator/derivation_formatter
  morphodita/derivator/derivator_dictionary
  morphodita/morpho/czech_morpho
  morphodita/morpho/english_morpho
  morphodita/morpho/english_morpho_guesser
  morphodita/morpho/external_morpho
  morphodita/morpho/generic_morpho
  morphodita/morpho/morpho
  morphodita/morpho/morpho_statistical_guesser
  morphodita/morpho/tag_filter
  morphodita/tagger/tagger
  morphodita/tagset_converter/identity_tagset_converter
  morphodita/tagset_converter/pdt_to_conll2009_tagset_converter
  morphodita/tagset_converter/strip_lemma_comment_tagset_converter
  morphodita/tagset_converter/strip_lemma_id_tagset_converter
  morphodita/tagset_converter/tagset_converter
  morphodita/tokenizer/czech_tokenizer
  morphodita/tokenizer/english_tokenizer
  morphodita/tokenizer/generic_tokenizer
  morphodita/tokenizer/ragel_tokenizer
  morphodita/tokenizer/tokenizer
  morphodita/tokenizer/unicode_tokenizer
  morphodita/tokenizer/vertical_tokenizer
  morphodita/version/version
  parsito/configuration/configuration
  parsito/configuration/node_extractor
  parsito/configuration/value_extractor
  parsito/embedding/embedding
  parsito/network/neural_network
  parsito/parser/parser
  parsito/parser/parser_nn
  parsito/transition/transition
  parsito/transition/transition_system
  parsito/transition/transition_system_link2
  parsito/transition/transition_system_projective
  parsito/transition/transition_system_swap
  parsito/tree/tree
  parsito/tree/tree_format
  parsito/tree/tree_format_conllu
  parsito/version/version
  model/evaluator
  model/model
  model/model_morphodita_parsito
  model/pipeline
  morphodita/morpho/generic_morpho_encoder
  morphodita/morpho/morpho_statistical_guesser_encoder
  morphodita/morpho/morpho_statistical_guesser_trainer
  morphodita/morpho/raw_morpho_dictionary_reader
  morphodita/tokenizer/czech_tokenizer_factory
  morphodita/tokenizer/czech_tokenizer_factory_encoder
  morphodita/tokenizer/generic_tokenizer_factory
  morphodita/tokenizer/generic_tokenizer_factory_encoder
  morphodita/tokenizer/gru_tokenizer
  morphodita/tokenizer/gru_tokenizer_factory
  morphodita/tokenizer/gru_tokenizer_network
  morphodita/tokenizer/gru_tokenizer_trainer
  morphodita/tokenizer/tokenizer_factory
  parsito/embedding/embedding_encode
  parsito/network/neural_network_trainer
  parsito/parser/parser_nn_trainer
  sentence/input_format
  sentence/output_format
  sentence/sentence
  sentence/token
  tokenizer/detokenizer
  tokenizer/morphodita_tokenizer_wrapper
  tokenizer/multiword_splitter
  tokenizer/multiword_splitter_trainer
  trainer/trainer
  trainer/trainer_morphodita_parsito
  trainer/training_failure
  unilib/unicode
  unilib/utf8
  unilib/uninorms
  unilib/version
  utils/compressor_load
  utils/compressor_save
  version/version)

set(UDPIPE_LIBRARY_SOURCES "")
foreach(relative_source IN LISTS UDPIPE_RELATIVE_SOURCES)
  list(APPEND UDPIPE_LIBRARY_SOURCES
    "${UDPIPE_SOURCE_ROOT}/${relative_source}.cpp")
endforeach()

function(tomato_configure_udpipe_target target_name)
  target_include_directories(${target_name} PUBLIC "${UDPIPE_SOURCE_ROOT}")
  target_compile_features(${target_name} PUBLIC cxx_std_17)
  if(MSVC)
    target_compile_options(${target_name} PRIVATE /utf-8 /EHsc /wd4244 /wd4267)
    target_compile_definitions(${target_name} PRIVATE _CRT_SECURE_NO_WARNINGS)
  else()
    target_compile_options(${target_name} PRIVATE -fexceptions -frtti)
  endif()
endfunction()
